/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright (C) 2020, Raspberry Pi (Trading) Ltd.
 *
 * mjpeg_encoder.cpp - mjpeg video encoder with VideoCore IV V4L2 M2M hardware acceleration.
 */

#include <algorithm>
#include <chrono>
#include <cstring>
#include <errno.h>
#include <fcntl.h>
#include <iostream>
#include <pthread.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <jpeglib.h>
#include <linux/videodev2.h>

#include <libcamera/libcamera.h>

#include "mjpeg_encoder.hpp"

#if JPEG_LIB_VERSION_MAJOR > 9 || (JPEG_LIB_VERSION_MAJOR == 9 && JPEG_LIB_VERSION_MINOR >= 4)
typedef size_t jpeg_mem_len_t;
#else
typedef unsigned long jpeg_mem_len_t;
#endif

MjpegEncoder::MjpegEncoder()
	: abortEncode_(false), abortOutput_(false), index_(0)
{
	for (int i = 0; i < NUM_ENC_THREADS; i++)
		encode_thread_[i] = std::thread(std::bind(&MjpegEncoder::encodeThread, this, i));
}

MjpegEncoder::~MjpegEncoder()
{
	{
		std::lock_guard<std::mutex> lock(encode_mutex_);
		abortEncode_ = true;
		encode_cond_var_.notify_all();
	}
	for (int i = 0; i < NUM_ENC_THREADS; i++) {
		if (encode_thread_[i].joinable())
			encode_thread_[i].join();
	}

	cleanupHwEncoder();
}

void MjpegEncoder::cleanupHwEncoder()
{
	if (hw_fd_ >= 0) {
		enum v4l2_buf_type type_out = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		enum v4l2_buf_type type_cap = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		ioctl(hw_fd_, VIDIOC_STREAMOFF, &type_out);
		ioctl(hw_fd_, VIDIOC_STREAMOFF, &type_cap);
	}
	if (hw_out_mem_ && hw_out_mem_ != MAP_FAILED && hw_out_mmap_len_ > 0) {
		munmap(hw_out_mem_, hw_out_mmap_len_);
	}
	hw_out_mem_ = nullptr;
	hw_out_mmap_len_ = 0;

	if (hw_cap_mem_ && hw_cap_mem_ != MAP_FAILED && hw_cap_mmap_len_ > 0) {
		munmap(hw_cap_mem_, hw_cap_mmap_len_);
	}
	hw_cap_mem_ = nullptr;
	hw_cap_mmap_len_ = 0;

	if (hw_fd_ >= 0) {
		struct v4l2_requestbuffers req = {};
		req.count = 0;
		req.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		req.memory = hw_dmabuf_ ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
		ioctl(hw_fd_, VIDIOC_REQBUFS, &req);

		memset(&req, 0, sizeof(req));
		req.count = 0;
		req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		req.memory = V4L2_MEMORY_MMAP;
		ioctl(hw_fd_, VIDIOC_REQBUFS, &req);

		close(hw_fd_);
		hw_fd_ = -1;
	}

	hw_width_ = 0;
	hw_height_ = 0;
	hw_stride_ = 0;
	hw_out_size_ = 0;
	hw_num_out_bufs_ = 0;
}

bool MjpegEncoder::initHwEncoder(StreamInfo const &info, bool use_dmabuf)
{
	cleanupHwEncoder();

	struct Candidate {
		const char *devnode;
		uint32_t pixfmt;
		const char *name;
	};
	static const Candidate candidates[] = {
		{ "/dev/video31", V4L2_PIX_FMT_JPEG,  "bcm2835-codec-encode_image (JPEG)" },
		{ "/dev/video11", V4L2_PIX_FMT_MJPEG, "bcm2835-codec-encode (MJPEG)" },
	};

	for (const auto &cand : candidates) {
		int fd = open(cand.devnode, O_RDWR);
		if (fd < 0)
			continue;

		struct v4l2_control ctrl = {};
		ctrl.id = V4L2_CID_JPEG_COMPRESSION_QUALITY;
		ctrl.value = 75;
		ioctl(fd, VIDIOC_S_CTRL, &ctrl);

		memset(&ctrl, 0, sizeof(ctrl));
		ctrl.id = V4L2_CID_MPEG_VIDEO_BITRATE;
		ctrl.value = 10000000;
		ioctl(fd, VIDIOC_S_CTRL, &ctrl);

		unsigned int req_stride = info.stride ? info.stride : info.width;
		unsigned int req_size = req_stride * info.height * 3 / 2;

		struct v4l2_format fmt_out = {};
		fmt_out.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		fmt_out.fmt.pix_mp.width = info.width;
		fmt_out.fmt.pix_mp.height = info.height;
		fmt_out.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_YUV420;
		fmt_out.fmt.pix_mp.field = V4L2_FIELD_NONE;
		fmt_out.fmt.pix_mp.colorspace = V4L2_COLORSPACE_JPEG;
		fmt_out.fmt.pix_mp.num_planes = 1;
		fmt_out.fmt.pix_mp.plane_fmt[0].bytesperline = req_stride;
		fmt_out.fmt.pix_mp.plane_fmt[0].sizeimage = req_size;

		if (ioctl(fd, VIDIOC_S_FMT, &fmt_out) < 0) {
			close(fd);
			continue;
		}

		struct v4l2_selection sel = {};
		sel.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
		sel.target = V4L2_SEL_TGT_CROP;
		sel.r.left = 0;
		sel.r.top = 0;
		sel.r.width = info.width;
		sel.r.height = info.height;
		ioctl(fd, VIDIOC_S_SELECTION, &sel);

		unsigned int got_stride = fmt_out.fmt.pix_mp.plane_fmt[0].bytesperline;
		unsigned int got_size = fmt_out.fmt.pix_mp.plane_fmt[0].sizeimage;

		/*
		 * Zero-copy DMABUF requires the encoder's row stride to match
		 * libcamera's row stride exactly. If they differ, use MMAP on
		 * the output queue and copy plane rows with stride adjustment.
		 */
		bool can_dmabuf = use_dmabuf && (got_stride == req_stride);

		struct v4l2_format fmt_cap = {};
		fmt_cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		fmt_cap.fmt.pix_mp.width = info.width;
		fmt_cap.fmt.pix_mp.height = info.height;
		fmt_cap.fmt.pix_mp.pixelformat = cand.pixfmt;
		fmt_cap.fmt.pix_mp.field = V4L2_FIELD_NONE;
		fmt_cap.fmt.pix_mp.num_planes = 1;
		fmt_cap.fmt.pix_mp.plane_fmt[0].bytesperline = 0;
		fmt_cap.fmt.pix_mp.plane_fmt[0].sizeimage = std::max(info.width * info.height * 2, 65536u);

		if (ioctl(fd, VIDIOC_S_FMT, &fmt_cap) < 0) {
			close(fd);
			continue;
		}

		struct v4l2_requestbuffers req_out = {};
		req_out.count = can_dmabuf ? 8 : 1;
		req_out.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		req_out.memory = can_dmabuf ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;

		if (ioctl(fd, VIDIOC_REQBUFS, &req_out) < 0 || req_out.count < 1) {
			close(fd);
			continue;
		}

		void *out_mem = nullptr;
		size_t out_mmap_len = 0;
		if (!can_dmabuf) {
			struct v4l2_plane out_plane = {};
			struct v4l2_buffer out_buf = {};
			out_buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
			out_buf.memory = V4L2_MEMORY_MMAP;
			out_buf.index = 0;
			out_buf.length = 1;
			out_buf.m.planes = &out_plane;
			if (ioctl(fd, VIDIOC_QUERYBUF, &out_buf) < 0) {
				close(fd);
				continue;
			}
			out_mmap_len = out_plane.length;
			out_mem = mmap(NULL, out_mmap_len, PROT_READ | PROT_WRITE,
				       MAP_SHARED, fd, out_plane.m.mem_offset);
			if (out_mem == MAP_FAILED) {
				close(fd);
				continue;
			}
		}

		struct v4l2_requestbuffers req_cap = {};
		req_cap.count = 1;
		req_cap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		req_cap.memory = V4L2_MEMORY_MMAP;

		if (ioctl(fd, VIDIOC_REQBUFS, &req_cap) < 0 || req_cap.count < 1) {
			if (out_mem && out_mem != MAP_FAILED)
				munmap(out_mem, out_mmap_len);
			close(fd);
			continue;
		}

		struct v4l2_plane cap_plane = {};
		struct v4l2_buffer cap_buf = {};
		cap_buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		cap_buf.memory = V4L2_MEMORY_MMAP;
		cap_buf.index = 0;
		cap_buf.length = 1;
		cap_buf.m.planes = &cap_plane;

		if (ioctl(fd, VIDIOC_QUERYBUF, &cap_buf) < 0) {
			if (out_mem && out_mem != MAP_FAILED)
				munmap(out_mem, out_mmap_len);
			close(fd);
			continue;
		}

		size_t cap_mmap_len = cap_plane.length;
		void *cap_mem = mmap(NULL, cap_mmap_len, PROT_READ | PROT_WRITE,
				     MAP_SHARED, fd, cap_plane.m.mem_offset);
		if (cap_mem == MAP_FAILED) {
			if (out_mem && out_mem != MAP_FAILED)
				munmap(out_mem, out_mmap_len);
			close(fd);
			continue;
		}

		enum v4l2_buf_type type_out = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		enum v4l2_buf_type type_cap = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		if (ioctl(fd, VIDIOC_STREAMON, &type_out) < 0 ||
		    ioctl(fd, VIDIOC_STREAMON, &type_cap) < 0) {
			munmap(cap_mem, cap_mmap_len);
			if (out_mem && out_mem != MAP_FAILED)
				munmap(out_mem, out_mmap_len);
			close(fd);
			continue;
		}

		hw_fd_ = fd;
		hw_dmabuf_ = can_dmabuf;
		hw_width_ = info.width;
		hw_height_ = info.height;
		hw_stride_ = got_stride;
		hw_out_size_ = got_size;
		hw_num_out_bufs_ = req_out.count;
		hw_out_mem_ = out_mem;
		hw_out_mmap_len_ = out_mmap_len;
		hw_cap_mem_ = cap_mem;
		hw_cap_mmap_len_ = cap_mmap_len;

		std::cout << "[GPU] Initialized VideoCore IV hardware encoder on " << cand.devnode
			  << " [" << cand.name << "] " << hw_width_ << "x" << hw_height_
			  << " (stride=" << hw_stride_ << ", dmabuf=" << (hw_dmabuf_ ? "yes" : "no") << ")"
			  << std::endl;
		return true;
	}

	std::cerr << "[GPU] VideoCore IV hardware encoder unavailable, falling back to CPU libjpeg" << std::endl;
	return false;
}

bool MjpegEncoder::encodeHW(EncodeItem &item, uint8_t *&encoded_buffer, size_t &buffer_len)
{
	if (hw_failed_)
		return false;

	bool want_dmabuf = (item.dmabuf_fd >= 0);
	if (hw_fd_ < 0 || hw_width_ != item.info.width || hw_height_ != item.info.height) {
		if (!initHwEncoder(item.info, want_dmabuf)) {
			hw_failed_ = true;
			return false;
		}
	}

	struct v4l2_plane cap_plane = {};
	struct v4l2_buffer cap_buf = {};
	cap_buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	cap_buf.memory = V4L2_MEMORY_MMAP;
	cap_buf.index = 0;
	cap_buf.length = 1;
	cap_buf.m.planes = &cap_plane;

	if (ioctl(hw_fd_, VIDIOC_QBUF, &cap_buf) < 0)
		return false;

	struct v4l2_plane out_plane = {};
	struct v4l2_buffer out_buf = {};
	out_buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	out_buf.length = 1;
	out_buf.m.planes = &out_plane;

	if (hw_dmabuf_) {
		out_buf.memory = V4L2_MEMORY_DMABUF;
		out_buf.index = item.cookie % hw_num_out_bufs_;
		out_plane.m.fd = item.dmabuf_fd;
		out_plane.bytesused = hw_out_size_;
		out_plane.length = hw_out_size_;

		if (ioctl(hw_fd_, VIDIOC_QBUF, &out_buf) < 0) {
			/*
			 * If DMABUF queueing fails, transparently reinitialize
			 * the hardware encoder in MMAP mode and retry.
			 */
			if (!initHwEncoder(item.info, false)) {
				hw_failed_ = true;
				return false;
			}
			return encodeHW(item, encoded_buffer, buffer_len);
		}
	} else {
		if (!item.mem || !hw_out_mem_)
			return false;

		unsigned int src_stride = item.info.stride ? item.info.stride : item.info.width;
		if (src_stride == hw_stride_) {
			size_t copy_bytes = std::min((size_t)item.size, (size_t)hw_out_size_);
			memcpy(hw_out_mem_, item.mem, copy_bytes);
		} else {
			const uint8_t *src_y = static_cast<const uint8_t *>(item.mem);
			const uint8_t *src_u = src_y + src_stride * item.info.height;
			const uint8_t *src_v = src_u + (src_stride / 2) * (item.info.height / 2);

			uint8_t *dst_y = static_cast<uint8_t *>(hw_out_mem_);
			uint8_t *dst_u = dst_y + hw_stride_ * item.info.height;
			uint8_t *dst_v = dst_u + (hw_stride_ / 2) * (item.info.height / 2);

			for (unsigned int y = 0; y < item.info.height; y++)
				memcpy(dst_y + y * hw_stride_, src_y + y * src_stride, item.info.width);
			for (unsigned int y = 0; y < item.info.height / 2; y++) {
				memcpy(dst_u + y * (hw_stride_ / 2), src_u + y * (src_stride / 2), item.info.width / 2);
				memcpy(dst_v + y * (hw_stride_ / 2), src_v + y * (src_stride / 2), item.info.width / 2);
			}
		}

		out_buf.memory = V4L2_MEMORY_MMAP;
		out_buf.index = 0;
		out_plane.bytesused = hw_out_size_;
		out_plane.length = hw_out_size_;

		if (ioctl(hw_fd_, VIDIOC_QBUF, &out_buf) < 0)
			return false;
	}

	if (ioctl(hw_fd_, VIDIOC_DQBUF, &out_buf) < 0)
		return false;
	if (ioctl(hw_fd_, VIDIOC_DQBUF, &cap_buf) < 0)
		return false;

	size_t bytesused = cap_buf.m.planes[0].bytesused;
	if (bytesused == 0 || bytesused > hw_cap_mmap_len_)
		return false;

	memcpy(encoded_buffer, hw_cap_mem_, bytesused);
	buffer_len = bytesused;
	return true;
}

void MjpegEncoder::EncodeBuffer(void *mem, void *dest, unsigned int size,
				StreamInfo const &info, int64_t timestamp_us,
				unsigned int cookie, int dmabuf_fd)
{
	std::lock_guard<std::mutex> lock(encode_mutex_);
	EncodeItem item = { mem, dest, size, info, timestamp_us, index_++, cookie, dmabuf_fd };

	encode_queue_.push(item);
	encode_cond_var_.notify_all();
}

void MjpegEncoder::encodeJPEG(struct jpeg_compress_struct &cinfo, EncodeItem &item,
			      uint8_t *&encoded_buffer, size_t &buffer_len)
{
	cinfo.image_width = item.info.width;
	cinfo.image_height = item.info.height;
	cinfo.input_components = 3;
	cinfo.in_color_space = JCS_YCbCr;
	cinfo.restart_interval = 0;

	jpeg_set_defaults(&cinfo);
	cinfo.raw_data_in = TRUE;
	jpeg_set_quality(&cinfo, 50, TRUE);
	cinfo.dct_method = JDCT_IFAST;

	jpeg_mem_len_t jpeg_mem_len = buffer_len;
	jpeg_mem_dest(&cinfo, &encoded_buffer, &jpeg_mem_len);
	jpeg_start_compress(&cinfo, TRUE);

	int stride2 = item.info.stride / 2;
	uint8_t *Y = (uint8_t *)item.mem;
	uint8_t *U = (uint8_t *)Y + item.info.stride * item.info.height;
	uint8_t *V = (uint8_t *)U + stride2 * (item.info.height / 2);
	uint8_t *Y_max = U - item.info.stride;
	uint8_t *U_max = V - stride2;
	uint8_t *V_max = U_max + stride2 * (item.info.height / 2);

	JSAMPROW y_rows[16];
	JSAMPROW u_rows[8];
	JSAMPROW v_rows[8];

	for (uint8_t *Y_row = Y, *U_row = U, *V_row = V; cinfo.next_scanline < item.info.height;)
	{
		for (int i = 0; i < 16; i++, Y_row += item.info.stride)
			y_rows[i] = std::min(Y_row, Y_max);
		for (int i = 0; i < 8; i++, U_row += stride2, V_row += stride2) {
			u_rows[i] = std::min(U_row, U_max);
			v_rows[i] = std::min(V_row, V_max);
		}

		JSAMPARRAY rows[] = { y_rows, u_rows, v_rows };
		jpeg_write_raw_data(&cinfo, rows, 16);
	}

	jpeg_finish_compress(&cinfo);

	buffer_len = jpeg_mem_len;
}

void MjpegEncoder::encodeThread(int num)
{
	(void)num;
	struct jpeg_compress_struct cinfo;
	struct jpeg_error_mgr jerr;
	EncodeItem encode_item;
	uint32_t frames = 0;

	cinfo.err = jpeg_std_error(&jerr);
	jpeg_create_compress(&cinfo);

	while (true)
	{
		{
			std::unique_lock<std::mutex> lock(encode_mutex_);
			while (true)
			{
				using namespace std::chrono_literals;
				if (abortEncode_)
				{
					jpeg_destroy_compress(&cinfo);
					return;
				}
				if (!encode_queue_.empty())
				{
					encode_item = encode_queue_.front();
					encode_queue_.pop();
					break;
				}
				else
					encode_cond_var_.wait_for(lock, 200ms);
			}
		}

		uint8_t *encoded_buffer = (uint8_t *)encode_item.dest;
		size_t buffer_len = encode_item.size;

		if (!encodeHW(encode_item, encoded_buffer, buffer_len)) {
			encodeJPEG(cinfo, encode_item, encoded_buffer, buffer_len);
		}

		frames++;

		if (!abortEncode_ && output_ready_callback_) {
			output_ready_callback_(encoded_buffer, buffer_len,
					       encode_item.timestamp_us, encode_item.cookie);
		}
	}
}

void MjpegEncoder::outputThread()
{
	OutputItem item;
	uint64_t index = 0;
	while (true)
	{
		{
			std::unique_lock<std::mutex> lock(output_mutex_);
			while (true)
			{
				using namespace std::chrono_literals;

				if (abortOutput_)
					return;

				for (auto &q : output_queue_)
				{
					if (!q.empty() && q.front().index == index)
					{
						item = q.front();
						q.pop();
						goto got_item;
					}
				}

				output_cond_var_.wait_for(lock, 200ms);
			}
		}
	got_item:
		output_ready_callback_(item.mem, item.bytes_used, item.timestamp_us, item.cookie);
		index++;
	}
}

StreamInfo MjpegEncoder::getStreamInfo(libcamera::Stream *stream)
{
	libcamera::StreamConfiguration const &cfg = stream->configuration();
	StreamInfo info;
	info.width = cfg.size.width;
	info.height = cfg.size.height;
	info.stride = cfg.stride;
	info.pixel_format = cfg.pixelFormat;
	info.colour_space = cfg.colorSpace;
	return info;
}
