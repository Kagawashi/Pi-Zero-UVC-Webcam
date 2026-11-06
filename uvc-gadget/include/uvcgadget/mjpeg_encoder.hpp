/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright (C) 2020, Raspberry Pi (Trading) Ltd.
 *
 * mjpeg_encoder.hpp - mjpeg video encoder (with VideoCore IV V4L2 M2M hardware acceleration).
 */

#pragma once

#include <condition_variable>
#include <functional>
#include <mutex>
#include <optional>
#include <queue>
#include <thread>

#include <libcamera/libcamera.h>

struct jpeg_compress_struct;
typedef std::function<void(void *, size_t, int64_t, unsigned int)> OutputReadyCallback;

struct StreamInfo
{
	StreamInfo() : width(0), height(0), stride(0) {}
	unsigned int width;
	unsigned int height;
	unsigned int stride;
	libcamera::PixelFormat pixel_format;
	std::optional<libcamera::ColorSpace> colour_space;
};

class MjpegEncoder
{
public:
	MjpegEncoder();
	~MjpegEncoder();

	void EncodeBuffer(void *mem, void *dest, unsigned int size,
			  StreamInfo const &info, int64_t timestamp_us,
			  unsigned int cookie, int dmabuf_fd = -1);
	StreamInfo getStreamInfo(libcamera::Stream *stream);
	void SetOutputReadyCallback(OutputReadyCallback callback) { output_ready_callback_ = callback; }

private:
	static const int NUM_ENC_THREADS = 1;

	void encodeThread(int num);
	void outputThread();

	bool abortEncode_;
	bool abortOutput_;
	uint64_t index_;

	struct EncodeItem
	{
		void *mem;
		void *dest;
		unsigned int size;
		StreamInfo info;
		int64_t timestamp_us;
		uint64_t index;
		unsigned int cookie;
		int dmabuf_fd;
	};

	std::queue<EncodeItem> encode_queue_;
	std::mutex encode_mutex_;
	std::condition_variable encode_cond_var_;
	std::thread encode_thread_[NUM_ENC_THREADS];

	void encodeJPEG(struct jpeg_compress_struct &cinfo, EncodeItem &item,
			uint8_t *&encoded_buffer, size_t &buffer_len);

	bool initHwEncoder(StreamInfo const &info, bool use_dmabuf);
	void cleanupHwEncoder();
	bool encodeHW(EncodeItem &item, uint8_t *&encoded_buffer, size_t &buffer_len);

	int hw_fd_ = -1;
	bool hw_failed_ = false;
	bool hw_dmabuf_ = false;
	unsigned int hw_width_ = 0;
	unsigned int hw_height_ = 0;
	unsigned int hw_stride_ = 0;
	unsigned int hw_out_size_ = 0;
	unsigned int hw_num_out_bufs_ = 0;
	void *hw_out_mem_ = nullptr;
	size_t hw_out_mmap_len_ = 0;
	void *hw_cap_mem_ = nullptr;
	size_t hw_cap_mmap_len_ = 0;

	struct OutputItem
	{
		void *mem;
		size_t bytes_used;
		int64_t timestamp_us;
		uint64_t index;
		unsigned int cookie;
	};

	std::queue<OutputItem> output_queue_[NUM_ENC_THREADS];
	std::mutex output_mutex_;
	std::condition_variable output_cond_var_;
	std::thread output_thread_;
	OutputReadyCallback output_ready_callback_;
};
