/* SPDX-License-Identifier: LGPL-2.1-or-later */
/*
 * libcamera source
 *
 * Copyright (C) 2022 Ideas on Board Oy
 *
 * Contact: Daniel Scally <dan.scally@ideasonboard.com>
 */

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <errno.h>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <map>
#include <memory.h>
#include <mutex>
#include <queue>
#include <stdlib.h>
#include <chrono>
#include <string>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>

#include <libcamera/libcamera.h>
#include <linux/videodev2.h>

#include "config.h"
#include "mjpeg_encoder.hpp"

extern "C" {
#include "events.h"
#include "libcamera-source.h"
#include "tools.h"
#include "video-buffers.h"
}

using namespace libcamera;
using namespace std::placeholders;

#define to_libcamera_source(s) container_of(s, struct libcamera_source, src)

struct libcamera_source {
	struct video_source src;

	std::unique_ptr<CameraManager> cm;
	std::unique_ptr<CameraConfiguration> config;
	std::shared_ptr<Camera> camera;
	ControlList controls;

	FrameBufferAllocator *allocator = nullptr;
	std::vector<std::unique_ptr<Request>> requests;
	std::queue<Request *> completed_requests;
	std::mutex requests_mutex;
	int pfds[2];

	MjpegEncoder *encoder = nullptr;
	std::unordered_map<FrameBuffer *, Span<uint8_t>> mapped_buffers_;

	struct video_buffer_set buffers;

	struct ReadyEncodedBuffer {
		unsigned int index;
		void *mem;
		size_t bytesused;
		int64_t timestamp;
	};
	std::queue<unsigned int> free_sink_bufs_;
	std::queue<ReadyEncodedBuffer> ready_encoded_;
	std::atomic<bool> stopping_{false};
	bool has_noise_reduction_ = false;
	bool auto_exposure_ = true;
	int32_t exposure_us_ = 5000;
	float analogue_gain_ = 8.0f;
	bool spatial_denoise_ = true;
	float brightness_ = 0.0f;
	float contrast_ = 1.0f;
	float saturation_ = 1.0f;
	float sharpness_ = 1.0f;
	bool controls_applied_ = false;
	bool applied_auto_exposure_ = true;
	int32_t applied_exposure_us_ = -1;
	float applied_analogue_gain_ = -1.0f;
	bool applied_spatial_denoise_ = true;
	float applied_brightness_ = 0.0f;
	float applied_contrast_ = 1.0f;
	float applied_saturation_ = 1.0f;
	float applied_sharpness_ = 1.0f;
	int64_t current_frame_time_us_ = 10000;
	time_t last_cfg_mtime_ = 0;
	std::chrono::steady_clock::time_point last_cfg_check_{};

	void checkDynamicConfig(int64_t frame_time_us);
	void mapBuffer(const std::unique_ptr<FrameBuffer> &buffer);
	void requestComplete(Request *request);
	void inputDone(unsigned int cookie);
	void outputReady(void *mem, size_t bytesused, int64_t timestamp, unsigned int cookie);
};

void libcamera_source::mapBuffer(const std::unique_ptr<FrameBuffer> &buffer)
{
	size_t buffer_size = 0;

	for (unsigned int i = 0; i < buffer->planes().size(); i++) {
		const FrameBuffer::Plane &plane = buffer->planes()[i];
		buffer_size += plane.length;

		if (i == buffer->planes().size() - 1 ||
			plane.fd.get() != buffer->planes()[i + 1].fd.get()) {
			void *memory = mmap(NULL, buffer_size, PROT_READ | PROT_WRITE,
						MAP_SHARED, plane.fd.get(), 0);
			mapped_buffers_[buffer.get()] =
				Span<uint8_t>(static_cast<uint8_t *>(memory), buffer_size);
			buffer_size = 0;
		}
	}
}

void libcamera_source::requestComplete(Request *request)
{
	if (request->status() == Request::RequestCancelled || stopping_.load())
		return;

	if (src.type == VIDEO_SOURCE_ENCODED && encoder) {
		unsigned int sink_idx = 0;
		{
			std::lock_guard<std::mutex> lock(requests_mutex);
			if (free_sink_bufs_.empty() || encoder->QueueSize() >= 2) {
				request->reuse(Request::ReuseBuffers);
				camera->queueRequest(request);
				return;
			}
			sink_idx = free_sink_bufs_.front();
			free_sink_bufs_.pop();
		}

		Stream *stream = config->at(0).stream();
		FrameBuffer *framebuf = request->buffers().begin()->second;
		int64_t timestamp_ns = framebuf->metadata().timestamp;
		StreamInfo info = encoder->getStreamInfo(stream);
		auto span = mapped_buffers_.find(framebuf);
		void *mem = (span != mapped_buffers_.end()) ? span->second.data() : nullptr;
		void *dest = buffers.buffers[sink_idx].mem;
		unsigned int size = (span != mapped_buffers_.end())
					    ? span->second.size()
					    : framebuf->planes()[0].length;
		int dmabuf_fd = framebuf->planes()[0].fd.get();
		unsigned int packed_cookie =
			(static_cast<unsigned int>(request->cookie()) << 16) | (sink_idx & 0xFFFFu);

		encoder->EncodeBuffer(mem, dest, size, info, timestamp_ns / 1000,
				      packed_cookie, dmabuf_fd);
		return;
	}

	{
		std::lock_guard<std::mutex> lock(requests_mutex);
		completed_requests.push(request);
	}

	/*
	 * We want to hand off to the event loop to do any further processing,
	 * which we can achieve by simply writing to the end of the pipe since
	 * the loop is polling the other end. Once the event loop picks up this
	 * write it will run libcamera_source_video_process().
	 */
	write(pfds[1], "x", 1);
}

namespace {

template <typename T>
T clamp_range(T val, T lo, T hi)
{
	return (val < lo) ? lo : ((val > hi) ? hi : val);
}

const char *find_json_value_start(const std::string &content, const char *key)
{
	size_t pos = content.find(key);
	if (pos == std::string::npos)
		return nullptr;
	size_t colon = content.find(':', pos);
	if (colon == std::string::npos)
		return nullptr;
	size_t val_start = content.find_first_not_of(" \t\r\n", colon + 1);
	if (val_start == std::string::npos)
		return nullptr;
	return content.c_str() + val_start;
}

bool parse_json_bool(const std::string &content, const char *key, bool &out)
{
	const char *val = find_json_value_start(content, key);
	if (!val)
		return false;
	if (strncmp(val, "true", 4) == 0) {
		out = true;
		return true;
	}
	if (strncmp(val, "false", 5) == 0) {
		out = false;
		return true;
	}
	return false;
}

bool parse_json_int(const std::string &content, const char *key, int &out)
{
	const char *val = find_json_value_start(content, key);
	if (!val)
		return false;
	char *endptr = nullptr;
	long parsed = std::strtol(val, &endptr, 10);
	if (endptr == val)
		return false;
	out = static_cast<int>(parsed);
	return true;
}

bool parse_json_float(const std::string &content, const char *key, float &out)
{
	const char *val = find_json_value_start(content, key);
	if (!val)
		return false;
	char *endptr = nullptr;
	float parsed = std::strtof(val, &endptr);
	if (endptr == val)
		return false;
	out = parsed;
	return true;
}

void set_if_non_neutral_or_changed(ControlList &ctrls, const ControlInfoMap &infoMap,
				   const Control<float> &ctrl, float val, float neutral,
				   float &applied)
{
	if ((std::fabs(val - neutral) > 1e-4f || std::fabs(val - applied) > 1e-4f) &&
	    infoMap.find(&ctrl) != infoMap.end()) {
		ctrls.set(ctrl, val);
		applied = val;
	}
}

void apply_tuning_controls(ControlList &ctrls, const Camera *cam,
			   bool has_noise_reduction, bool spatial_denoise,
			   float brightness, float &applied_brightness,
			   float contrast, float &applied_contrast,
			   float saturation, float &applied_saturation,
			   float sharpness, float &applied_sharpness)
{
	const ControlInfoMap &infoMap = cam->controls();
	if (has_noise_reduction) {
		ctrls.set(controls::draft::NoiseReductionMode,
			  spatial_denoise ? controls::draft::NoiseReductionModeFast
					  : controls::draft::NoiseReductionModeOff);
	}
	set_if_non_neutral_or_changed(ctrls, infoMap, controls::Brightness, brightness, 0.0f,
				      applied_brightness);
	set_if_non_neutral_or_changed(ctrls, infoMap, controls::Contrast, contrast, 1.0f,
				      applied_contrast);
	set_if_non_neutral_or_changed(ctrls, infoMap, controls::Saturation, saturation, 1.0f,
				      applied_saturation);
	set_if_non_neutral_or_changed(ctrls, infoMap, controls::Sharpness, sharpness, 1.0f,
				      applied_sharpness);
}

} /* namespace */

void libcamera_source::checkDynamicConfig(int64_t frame_time_us)
{
	auto now = std::chrono::steady_clock::now();
	if (last_cfg_check_.time_since_epoch().count() != 0 &&
	    std::chrono::duration_cast<std::chrono::milliseconds>(now - last_cfg_check_).count() < 500) {
		return;
	}
	last_cfg_check_ = now;

	struct stat st;
	if (stat("/etc/picam/config.json", &st) != 0)
		return;

	if (st.st_mtime == last_cfg_mtime_)
		return;

	last_cfg_mtime_ = st.st_mtime;

	std::ifstream cfg_file("/etc/picam/config.json");
	if (!cfg_file.is_open())
		return;

	std::string content((std::istreambuf_iterator<char>(cfg_file)),
			    std::istreambuf_iterator<char>());
	cfg_file.close();

	parse_json_bool(content, "\"auto_exposure\"", auto_exposure_);
	parse_json_bool(content, "\"spatial_denoise\"", spatial_denoise_);

	int exp_val = 0;
	if (parse_json_int(content, "\"exposure_value\"", exp_val) && exp_val > 0)
		exposure_us_ = exp_val;

	float gain_val = 0.0f;
	if (parse_json_float(content, "\"analogue_gain\"", gain_val))
		analogue_gain_ = clamp_range(gain_val, 1.0f, 16.0f);

	int ui_val = 0;
	if (parse_json_int(content, "\"brightness\"", ui_val))
		brightness_ = (clamp_range(ui_val, 0, 100) - 50) / 50.0f;
	if (parse_json_int(content, "\"contrast\"", ui_val))
		contrast_ = clamp_range(ui_val, 0, 100) / 50.0f;
	if (parse_json_int(content, "\"saturation\"", ui_val))
		saturation_ = clamp_range(ui_val, 0, 100) / 50.0f;
	if (parse_json_int(content, "\"sharpness\"", ui_val))
		sharpness_ = clamp_range(ui_val, 0, 100) / 50.0f;

	if (frame_time_us > 200 && exposure_us_ > frame_time_us - 200)
		exposure_us_ = static_cast<int32_t>(frame_time_us - 200);
}

void libcamera_source::inputDone(unsigned int cookie)
{
	if (stopping_.load())
		return;

	checkDynamicConfig(current_frame_time_us_);

	unsigned int req_idx = cookie >> 16;
	if (req_idx < requests.size()) {
		Request *r = requests[req_idx].get();
		r->reuse(Request::ReuseBuffers);

		if (!controls_applied_ || auto_exposure_ != applied_auto_exposure_ ||
		    (!auto_exposure_ && (exposure_us_ != applied_exposure_us_ ||
					 analogue_gain_ != applied_analogue_gain_)) ||
		    spatial_denoise_ != applied_spatial_denoise_ ||
		    brightness_ != applied_brightness_ ||
		    contrast_ != applied_contrast_ ||
		    saturation_ != applied_saturation_ ||
		    sharpness_ != applied_sharpness_) {
			if (!auto_exposure_) {
				r->controls().set(controls::AeEnable, false);
				r->controls().set(controls::ExposureTime, exposure_us_);
				r->controls().set(controls::AnalogueGain, analogue_gain_);
			} else {
				r->controls().set(controls::AeEnable, true);
			}

			apply_tuning_controls(r->controls(), camera.get(),
					      has_noise_reduction_, spatial_denoise_,
					      brightness_, applied_brightness_,
					      contrast_, applied_contrast_,
					      saturation_, applied_saturation_,
					      sharpness_, applied_sharpness_);

			controls_applied_ = true;
			applied_auto_exposure_ = auto_exposure_;
			applied_exposure_us_ = exposure_us_;
			applied_analogue_gain_ = analogue_gain_;
			applied_spatial_denoise_ = spatial_denoise_;
		}

		camera->queueRequest(r);
	}
}

void libcamera_source::outputReady(void *mem, size_t bytesused, int64_t timestamp, unsigned int cookie)
{
	if (stopping_.load())
		return;

	unsigned int sink_idx = cookie & 0xFFFFu;
	{
		std::lock_guard<std::mutex> lock(requests_mutex);
		ready_encoded_.push({ sink_idx, mem, bytesused, timestamp });
	}
	write(pfds[1], "x", 1);
}

static void libcamera_source_video_process(void *d)
{
	struct libcamera_source *src = (struct libcamera_source *)d;
	char drain[64];

	/*
	 * Drain all notification bytes from the non-blocking pipe and process
	 * all completed requests in one wakeup to avoid extra select() roundtrips.
	 */
	while (read(src->pfds[0], drain, sizeof(drain)) > 0) {
	}

	if (src->src.type == VIDEO_SOURCE_ENCODED) {
		while (true) {
			libcamera_source::ReadyEncodedBuffer item;
			{
				std::lock_guard<std::mutex> lock(src->requests_mutex);
				if (src->ready_encoded_.empty())
					return;
				item = src->ready_encoded_.front();
				src->ready_encoded_.pop();
			}

			struct video_buffer buffer = {};
			buffer.index = item.index;
			buffer.mem = item.mem;
			buffer.bytesused = item.bytesused;
			buffer.timestamp.tv_sec = item.timestamp / 1000000;
			buffer.timestamp.tv_usec = item.timestamp % 1000000;
			buffer.error = false;

			src->src.handler(src->src.handler_data, &src->src, &buffer);
		}
	}

	while (true) {
		Request *request = nullptr;
		{
			std::lock_guard<std::mutex> lock(src->requests_mutex);
			if (src->completed_requests.empty())
				return;

			request = src->completed_requests.front();
			src->completed_requests.pop();
		}

		/* We have only a single buffer per request, so just pick the first */
		FrameBuffer *framebuf = request->buffers().begin()->second;

		int64_t timestamp_us = framebuf->metadata().timestamp / 1000;
		struct video_buffer buffer;
		buffer.index = request->cookie();
		buffer.size = framebuf->planes()[0].length;
		buffer.mem = NULL;
		buffer.bytesused = framebuf->metadata().planes()[0].bytesused;
		buffer.timestamp.tv_sec = timestamp_us / 1000000;
		buffer.timestamp.tv_usec = timestamp_us % 1000000;
		buffer.error = false;

		src->src.handler(src->src.handler_data, &src->src, &buffer);
	}
}

static void libcamera_source_destroy(struct video_source *s)
{
	struct libcamera_source *src = to_libcamera_source(s);

	src->camera->requestCompleted.disconnect(src);

	if (src->encoder) {
		delete src->encoder;
		src->encoder = nullptr;
	}

	/* Closing the event notification file descriptors */
	close(src->pfds[0]);
	close(src->pfds[1]);

	src->camera->release();
	src->camera.reset();
	src->cm->stop();
	delete src;
}

static void update_fast_crop_for_resolution(unsigned int width, unsigned int height)
{
	const char *sys_path = "/sys/module/ov5647/parameters/fast_crop";
	if (access(sys_path, W_OK) != 0)
		return;

	// Default policy: fast_crop=false by default. Mode 3 (640x480 @ 100 FPS) is used
	// and cleanly downscaled by bcm2835-isp hardware, avoiding sensor Bayer misalignment artifacts.
	bool enable_fast_crop = false;

	// Read override from /etc/picam/config.json if present
	std::ifstream cfg_file("/etc/picam/config.json");
	if (cfg_file.is_open()) {
		std::string content((std::istreambuf_iterator<char>(cfg_file)),
				    std::istreambuf_iterator<char>());
		cfg_file.close();

		char key[64];
		snprintf(key, sizeof(key), "\"%ux%u\"", width, height);
		size_t pos = content.find(key);
		if (pos != std::string::npos) {
			size_t colon = content.find(':', pos);
			if (colon != std::string::npos) {
				size_t val_start = content.find_first_not_of(" \t\r\n", colon + 1);
				if (val_start != std::string::npos) {
					if (content.compare(val_start, 4, "true") == 0)
						enable_fast_crop = true;
					else if (content.compare(val_start, 5, "false") == 0)
						enable_fast_crop = false;
				}
			}
		}
	}

	std::ofstream sys_file(sys_path);
	if (sys_file.is_open()) {
		sys_file << (enable_fast_crop ? "1" : "0") << std::endl;
		sys_file.close();
		std::cout << "[libcamera-source] Fast Crop for " << width << "x" << height
			  << " -> " << (enable_fast_crop ? "ENABLED (High-FPS Cropped Mode)" : "DISABLED (Full FOV)")
			  << std::endl;
	}
}

static int libcamera_source_set_format(struct video_source *s,
				       struct v4l2_pix_format *fmt)
{
	struct libcamera_source *src = to_libcamera_source(s);

	update_fast_crop_for_resolution(fmt->width, fmt->height);

	StreamConfiguration &streamConfig = src->config->at(0);
	__u32 chosen_pixelformat = fmt->pixelformat;

	if (src->encoder) {
		delete src->encoder;
		src->encoder = nullptr;
	}
	src->src.type = VIDEO_SOURCE_DMABUF;

	streamConfig.size.width = fmt->width;
	streamConfig.size.height = fmt->height;
	streamConfig.stride = 0;
	streamConfig.pixelFormat = PixelFormat(chosen_pixelformat);

	src->config->validate();

#ifdef CONFIG_CAN_ENCODE
	/*
	 * If the user requests MJPEG but the camera can't supply it, try again
	 * with YUV420 and initialise an MjpegEncoder to compress the data.
	 */
	if (chosen_pixelformat == V4L2_PIX_FMT_MJPEG &&
	    streamConfig.pixelFormat.fourcc() != chosen_pixelformat) {
		std::cout << "MJPEG format not natively supported; encoding YUV420 via VideoCore IV GPU" << std::endl;

		src->encoder = new MjpegEncoder();
		src->encoder->SetInputDoneCallback(std::bind(&libcamera_source::inputDone, src, _1));
		src->encoder->SetOutputReadyCallback(std::bind(&libcamera_source::outputReady, src, _1, _2, _3, _4));

		streamConfig.pixelFormat = PixelFormat(V4L2_PIX_FMT_YUV420);
		streamConfig.stride = 0;
		streamConfig.colorSpace = ColorSpace::Sycc;
		src->src.type = VIDEO_SOURCE_ENCODED;

		src->config->validate();
	}
#endif

	if (fmt->pixelformat != streamConfig.pixelFormat.fourcc() && !src->encoder)
		std::cerr << "Warning: set_format: Requested format unavailable" << std::endl;

	std::cout << "setting format to " << streamConfig.toString() << std::endl;

	/*
	 * No .configure() call at this stage, because we need to pick up the
	 * number of buffers to use later on so we'd need to call it then too.
	 */

	fmt->width = streamConfig.size.width;
	fmt->height = streamConfig.size.height;
	fmt->pixelformat = src->encoder ? V4L2_PIX_FMT_MJPEG : streamConfig.pixelFormat.fourcc();
	fmt->field = V4L2_FIELD_ANY;

	/* TODO: Can we use libcamera helpers to get image size / stride? */
	if (fmt->pixelformat == V4L2_PIX_FMT_MJPEG) {
		unsigned int mjpeg_size = fmt->width * fmt->height;
		fmt->sizeimage = (mjpeg_size > 65536u) ? mjpeg_size : 65536u;
	} else {
		fmt->sizeimage = fmt->width * fmt->height * 2;
	}

	return 0;
}

static int libcamera_source_set_frame_rate(struct video_source *s, unsigned int fps)
{
	struct libcamera_source *src = to_libcamera_source(s);
	int64_t frame_time = 1000000 / (fps ? fps : 30);

	std::cout << "Setting libcamera FrameDurationLimits to " << frame_time
		  << " us (" << fps << " fps)" << std::endl;

	src->controls.set(controls::FrameDurationLimits,
			  Span<const int64_t, 2>({ frame_time, frame_time }));

	src->current_frame_time_us_ = frame_time;
	src->last_cfg_check_ = {};
	src->last_cfg_mtime_ = 0;
	src->checkDynamicConfig(frame_time);

	if (frame_time > 200 && src->exposure_us_ > frame_time - 200)
		src->exposure_us_ = static_cast<int32_t>(frame_time - 200);

	if (!src->auto_exposure_) {
		src->controls.set(controls::AeEnable, false);
		src->controls.set(controls::ExposureTime, src->exposure_us_);
		src->controls.set(controls::AnalogueGain, src->analogue_gain_);
		std::cout << "Manual exposure enabled in libcamera: ExposureTime="
			  << src->exposure_us_ << " us, AnalogueGain=" << src->analogue_gain_ << std::endl;
	} else {
		src->controls.set(controls::AeEnable, true);
	}

	apply_tuning_controls(src->controls, src->camera.get(),
			      src->has_noise_reduction_, src->spatial_denoise_,
			      src->brightness_, src->applied_brightness_,
			      src->contrast_, src->applied_contrast_,
			      src->saturation_, src->applied_saturation_,
			      src->sharpness_, src->applied_sharpness_);

	return 0;
}

static int libcamera_source_alloc_buffers(struct video_source *s, unsigned int nbufs)
{
	struct libcamera_source *src = to_libcamera_source(s);
	StreamConfiguration &streamConfig = src->config->at(0);
	int ret;

	streamConfig.bufferCount = nbufs;
	ret = src->camera->configure(src->config.get());
	if (ret) {
		std::cerr << "failed to configure the camera" << std::endl;
		return ret;
	}

	Stream *stream = src->config->at(0).stream();
	FrameBufferAllocator *allocator;

	allocator = new FrameBufferAllocator(src->camera);

	ret = allocator->allocate(stream);
	if (ret < 0) {
		std::cerr << "failed to allocate buffers" << std::endl;
		delete allocator;
		return ret;
	}

	src->allocator = allocator;

	const std::vector<std::unique_ptr<FrameBuffer>> &buffers = allocator->buffers(stream);
	src->buffers.nbufs = buffers.size();

	if (src->src.type == VIDEO_SOURCE_ENCODED) {
		for (const std::unique_ptr<FrameBuffer> &buffer : buffers)
			src->mapBuffer(buffer);
	}

	src->buffers.buffers = (video_buffer *)calloc(src->buffers.nbufs, sizeof(*src->buffers.buffers));
	if (!src->buffers.buffers) {
		std::cerr << "failed to allocate buffers" << std::endl;
		return -ENOMEM;
	}

	for (unsigned int i = 0; i < buffers.size(); ++i) {
		src->buffers.buffers[i].index = i;
		src->buffers.buffers[i].dmabuf = -1;
	}

	return ret;
}

static int libcamera_source_export_buffers(struct video_source *s,
					   struct video_buffer_set **bufs)
{
	struct libcamera_source *src = to_libcamera_source(s);
	Stream *stream = src->config->at(0).stream();
	const std::vector<std::unique_ptr<FrameBuffer>> &buffers = src->allocator->buffers(stream);
	struct video_buffer_set *vid_buf_set;
	unsigned int i;

	for (i = 0; i < buffers.size(); i++) {
		const std::unique_ptr<FrameBuffer> &buffer = buffers[i];

		src->buffers.buffers[i].size = buffer->planes()[0].length;
		src->buffers.buffers[i].dmabuf = buffer->planes()[0].fd.get();
	}

	vid_buf_set = video_buffer_set_new(buffers.size());
	if (!vid_buf_set)
		return -ENOMEM;

	for (i = 0; i < src->buffers.nbufs; ++i) {
		struct video_buffer *buffer = &src->buffers.buffers[i];

		vid_buf_set->buffers[i].size = buffer->size;
		vid_buf_set->buffers[i].dmabuf = buffer->dmabuf;
	}

	*bufs = vid_buf_set;

	return 0;
}

static int libcamera_source_import_buffers(struct video_source *s,
					   struct video_buffer_set *buffers)
{
	struct libcamera_source *src = to_libcamera_source(s);

	for (unsigned int i = 0; i < buffers->nbufs; i++) {
		src->buffers.buffers[i].mem = buffers->buffers[i].mem;
		src->buffers.buffers[i].size = buffers->buffers[i].size;
	}

	return 0;
}

static int libcamera_source_free_buffers(struct video_source *s)
{
	struct libcamera_source *src = to_libcamera_source(s);
	Stream *stream = src->config->at(0).stream();

	for (auto &[buf, span] : src->mapped_buffers_)
		munmap(span.data(), span.size());

	src->mapped_buffers_.clear();

	if (src->allocator) {
		src->allocator->free(stream);
		delete src->allocator;
		src->allocator = nullptr;
	}
	free(src->buffers.buffers);
	src->buffers.buffers = nullptr;

	return 0;
}

static int libcamera_source_stream_on(struct video_source *s)
{
	struct libcamera_source *src = to_libcamera_source(s);
	Stream *stream = src->config->at(0).stream();
	int ret;

	src->stopping_.store(false);
	src->controls_applied_ = false;
	{
		std::lock_guard<std::mutex> lock(src->requests_mutex);
		while (!src->free_sink_bufs_.empty())
			src->free_sink_bufs_.pop();
		while (!src->ready_encoded_.empty())
			src->ready_encoded_.pop();
		for (unsigned int i = 0; i < src->buffers.nbufs; ++i)
			src->free_sink_bufs_.push(i);
	}

#ifdef CONFIG_CAN_ENCODE
	if (src->src.type == VIDEO_SOURCE_ENCODED && !src->encoder) {
		src->encoder = new MjpegEncoder();
		src->encoder->SetInputDoneCallback(std::bind(&libcamera_source::inputDone, src, _1));
		src->encoder->SetOutputReadyCallback(std::bind(&libcamera_source::outputReady, src, _1, _2, _3, _4));
	}
#endif

	const std::vector<std::unique_ptr<FrameBuffer>> &buffers = src->allocator->buffers(stream);

	for (unsigned int i = 0; i < buffers.size(); ++i) {
		std::unique_ptr<Request> request = src->camera->createRequest(i);
		if (!request) {
			std::cerr << "failed to create request" << std::endl;
			return -ENOMEM;
		}

		const std::unique_ptr<FrameBuffer> &buffer = buffers[i];
		ret = request->addBuffer(stream, buffer.get());
		if (ret < 0) {
			std::cerr << "failed to set buffer for request" << std::endl;
			return ret;
		}

		src->requests.push_back(std::move(request));
	}

	ret = src->camera->start(&src->controls);
	if (ret) {
		std::cerr << "failed to start camera" << std::endl;
		return ret;
	}

	for (std::unique_ptr<Request> &request : src->requests) {
		ret = src->camera->queueRequest(request.get());
		if (ret) {
			std::cerr << "failed to queue request" << std::endl;
			src->camera->stop();
			return ret;
		}
	}

	/*
	 * Given our event handling code is designed for V4L2 file descriptors
	 * and lacks a way to trigger an event manually, we're using a pipe so
	 * that we can watch the read end and write to the other end when
	 * requestComplete() is ran.
	 */
	events_watch_fd(src->src.events, src->pfds[0], EVENT_READ,
			libcamera_source_video_process, src);

	return 0;
}

static int libcamera_source_stream_off(struct video_source *s)
{
	struct libcamera_source *src = to_libcamera_source(s);

	src->stopping_.store(true);

	if (src->encoder) {
		delete src->encoder;
		src->encoder = nullptr;
	}

	src->camera->stop();
	events_unwatch_fd(src->src.events, src->pfds[0], EVENT_READ);
	src->requests.clear();

	{
		std::lock_guard<std::mutex> lock(src->requests_mutex);
		while (!src->completed_requests.empty())
			src->completed_requests.pop();
		while (!src->free_sink_bufs_.empty())
			src->free_sink_bufs_.pop();
		while (!src->ready_encoded_.empty())
			src->ready_encoded_.pop();
	}

	/* Drain any remaining notification bytes from the pipe */
	char drain_buf[64];
	while (read(src->pfds[0], drain_buf, sizeof(drain_buf)) > 0) {
	}

	return 0;
}

static int libcamera_source_queue_buffer(struct video_source *s,
					 struct video_buffer *buf)
{
	struct libcamera_source *src = to_libcamera_source(s);

	if (src->src.type == VIDEO_SOURCE_ENCODED) {
		std::lock_guard<std::mutex> lock(src->requests_mutex);
		src->free_sink_bufs_.push(buf->index);
		return 0;
	}

	for (std::unique_ptr<Request> &r : src->requests) {
		if (r->cookie() == buf->index) {
			r->reuse(Request::ReuseBuffers);
			src->camera->queueRequest(r.get());

			break;
		}
	}

	return 0;
}

static const struct video_source_ops libcamera_source_ops = {
	.destroy = libcamera_source_destroy,
	.set_format = libcamera_source_set_format,
	.set_frame_rate = libcamera_source_set_frame_rate,
	.alloc_buffers = libcamera_source_alloc_buffers,
	.export_buffers = libcamera_source_export_buffers,
	.import_buffers = libcamera_source_import_buffers,
	.free_buffers = libcamera_source_free_buffers,
	.stream_on = libcamera_source_stream_on,
	.stream_off = libcamera_source_stream_off,
	.queue_buffer = libcamera_source_queue_buffer,
	.fill_buffer = NULL,
};

std::string cameraName(Camera *camera)
{
	const ControlList &props = camera->properties();
	std::string name;

	const auto &location = props.get(properties::Location);
	if (location) {
		switch (*location) {
		case properties::CameraLocationFront:
			name = "Internal Front Camera";
			break;
		case properties::CameraLocationBack:
			name = "Internal back camera";
			break;
		case properties::CameraLocationExternal:
			name = "External camera";
			const auto &model = props.get(properties::Model);
			if (model)
				name = *model;
			break;
		}
	}
	name += " (" + camera->id() + ")";

	return name;
}

struct video_source *libcamera_source_create(const char *devname)
{
	struct libcamera_source *src;
	int ret;

	if (!devname) {
		std::cerr << "No camera identifier was passed" << std::endl;
		return NULL;
	}

	src = new libcamera_source;

	ret = pipe2(src->pfds, O_NONBLOCK);
	if (ret) {
		std::cerr << "failed to create pipe" << std::endl;
		goto err_free_src;
	}

	src->src.ops = &libcamera_source_ops;
	src->src.type = VIDEO_SOURCE_DMABUF;

	src->cm = std::make_unique<CameraManager>();
	src->cm->start();

	if (src->cm->cameras().empty()) {
		std::cout << "No cameras were identified on the system" << std::endl;
		goto err_close_pipe;
	}

	/* TODO: make a separate way to list libcamera cameras */
	for (auto const &camera : src->cm->cameras())
		printf("- %s\n", cameraName(camera.get()).c_str());

	/*
	 * Camera selection is by ID or index. Camera ID's start with a slash.
	 * If the first character is a digit, assume we're indexing, otherwise
	 * treat it as an ID.
	 */
	if (std::isdigit(devname[0])) {
		unsigned long index = std::atoi(devname);

		if (index >= src->cm->cameras().size()) {
			std::cerr << "No camera at index " << index << std::endl;
			goto err_close_pipe;
		}

		src->camera = src->cm->cameras()[index];
	} else {
		src->camera = src->cm->get(std::string(devname));
		if (!src->camera) {
			std::cerr << "found no camera matching " << devname << std::endl;
			goto err_close_pipe;
		}
	}

	ret = src->camera->acquire();
	if (ret) {
		fprintf(stderr, "failed to acquire camera\n");
		goto err_close_pipe;
	}

	std::cout << "Using camera " << cameraName(src->camera.get()) << std::endl;

	src->config =
		src->camera->generateConfiguration( { StreamRole::VideoRecording });
	if (!src->config) {
		std::cerr << "failed to generate camera config" << std::endl;
		goto err_release_camera;
	}

	src->camera->requestCompleted.connect(src, &libcamera_source::requestComplete);

	{
		const ControlInfoMap &infoMap = src->camera->controls();
		if (infoMap.find(&controls::AfMode) != infoMap.end()) {
			std::cout << "Enabling continuous auto-focus" << std::endl;
			src->controls.set(controls::AfMode, controls::AfModeContinuous);
		}
		if (infoMap.find(&controls::draft::NoiseReductionMode) != infoMap.end()) {
			src->controls.set(controls::draft::NoiseReductionMode,
					  controls::draft::NoiseReductionModeFast);
			src->has_noise_reduction_ = true;
			std::cout << "Enabling VideoCore IV GPU Hardware Spatial Denoise (NoiseReductionModeFast)" << std::endl;
		}
	}

	/* Seed initial fallback defaults from environment before reading /etc/picam/config.json */
	{
		const char *ae_env = getenv("PICAM_AUTO_EXPOSURE");
		const char *exp_env = getenv("PICAM_EXPOSURE_US");
		if (ae_env) {
			if (strcmp(ae_env, "false") == 0 || strcmp(ae_env, "0") == 0)
				src->auto_exposure_ = false;
			else if (strcmp(ae_env, "true") == 0 || strcmp(ae_env, "1") == 0)
				src->auto_exposure_ = true;
		}
		if (exp_env) {
			int val = std::atoi(exp_env);
			if (val > 0)
				src->exposure_us_ = val;
		}
	}

	return &src->src;

err_release_camera:
	src->camera->release();
err_close_pipe:
	close(src->pfds[0]);
	close(src->pfds[1]);
	src->cm->stop();
err_free_src:
	delete src;

	return NULL;
}

void libcamera_source_init(struct video_source *s, struct events *events)
{
	struct libcamera_source *src = to_libcamera_source(s);

	src->src.events = events;
}
