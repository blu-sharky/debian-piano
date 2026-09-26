// SPDX-License-Identifier: GPL-2.0-only
/*
 * piano-bt-scan — minimal Bluetooth proof for the piano debug image.
 *
 * Usage: piano-bt-scan [hci-index] [seconds]
 *
 * Brings the controller up, prints its BD address and version, runs an LE
 * passive scan for a few seconds and prints every advertiser seen.  Talks
 * raw HCI over an AF_BLUETOOTH socket, so no BlueZ userspace is needed.
 * The socket ABI constants are copied here because the kernel does not
 * export the Bluetooth headers as UAPI.
 */
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#ifndef AF_BLUETOOTH
#define AF_BLUETOOTH		31
#endif
#define BTPROTO_HCI		1
#define SOL_HCI			0
#define HCI_FILTER		2
#define HCI_CHANNEL_RAW		0

#define HCIDEVUP		_IOW('H', 201, int)

#define HCI_COMMAND_PKT		0x01
#define HCI_EVENT_PKT		0x04

#define EVT_CMD_COMPLETE	0x0e
#define EVT_CMD_STATUS		0x0f
#define EVT_LE_META		0x3e
#define EVT_LE_ADV_REPORT	0x02

#define OP(ogf, ocf)		((uint16_t)(((ogf) << 10) | (ocf)))
#define OP_RESET		OP(0x03, 0x0003)
#define OP_READ_LOCAL_VERSION	OP(0x04, 0x0001)
#define OP_READ_BD_ADDR		OP(0x04, 0x0009)
#define OP_LE_SET_SCAN_PARAMS	OP(0x08, 0x000b)
#define OP_LE_SET_SCAN_ENABLE	OP(0x08, 0x000c)
#define OP_SET_EVENT_MASK	OP(0x03, 0x0001)
#define OP_LE_SET_EVENT_MASK	OP(0x08, 0x0001)

struct sockaddr_hci {
	sa_family_t hci_family;
	unsigned short hci_dev;
	unsigned short hci_channel;
};

struct hci_filter {
	uint32_t type_mask;
	uint32_t event_mask[2];
	uint16_t opcode;
};

static int send_cmd(int fd, uint16_t op, const void *param, uint8_t plen)
{
	uint8_t buf[260];

	buf[0] = HCI_COMMAND_PKT;
	buf[1] = op & 0xff;
	buf[2] = op >> 8;
	buf[3] = plen;
	if (plen)
		memcpy(buf + 4, param, plen);
	return write(fd, buf, 4 + plen) == 4 + plen ? 0 : -1;
}

/* wait for Command Complete of @op; copy its return parameters */
static int wait_cc(int fd, uint16_t op, uint8_t *rp, int rp_len)
{
	uint8_t buf[260];
	struct pollfd p = { .fd = fd, .events = POLLIN };

	for (;;) {
		int n;

		if (poll(&p, 1, 3000) <= 0)
			return -ETIMEDOUT;
		n = read(fd, buf, sizeof(buf));
		if (n < 3 || buf[0] != HCI_EVENT_PKT)
			continue;
		if (buf[1] == EVT_CMD_COMPLETE && n >= 7 &&
		    (buf[4] | buf[5] << 8) == op) {
			int len = n - 6;

			if (len > rp_len)
				len = rp_len;
			memcpy(rp, buf + 6, len);
			return len;
		}
		if (buf[1] == EVT_CMD_STATUS && n >= 7 &&
		    (buf[5] | buf[6] << 8) == op && buf[3])
			return -EIO;
	}
}

static int cmd(int fd, uint16_t op, const void *param, uint8_t plen,
	       uint8_t *rp, int rp_len)
{
	uint8_t tmp[64];
	int ret;

	if (!rp) {
		rp = tmp;
		rp_len = sizeof(tmp);
	}
	if (send_cmd(fd, op, param, plen))
		return -errno;
	ret = wait_cc(fd, op, rp, rp_len);
	if (ret > 0 && rp[0]) {
		fprintf(stderr, "opcode 0x%04x: HCI status 0x%02x\n", op, rp[0]);
		return -EIO;
	}
	return ret;
}

int main(int argc, char **argv)
{
	int dev = argc > 1 ? atoi(argv[1]) : 0;
	int secs = argc > 2 ? atoi(argv[2]) : 10;
	struct sockaddr_hci a = { AF_BLUETOOTH, 0, HCI_CHANNEL_RAW };
	struct hci_filter f;
	uint8_t rp[64], buf[260];
	struct pollfd p;
	time_t end;
	int fd, ctl, seen = 0;

	ctl = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	if (ctl < 0) {
		perror("socket");
		return 1;
	}
	if (ioctl(ctl, HCIDEVUP, dev) && errno != EALREADY) {
		perror("HCIDEVUP");
		return 1;
	}

	fd = socket(AF_BLUETOOTH, SOCK_RAW | SOCK_CLOEXEC, BTPROTO_HCI);
	a.hci_dev = dev;
	if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof(a))) {
		perror("bind");
		return 1;
	}
	memset(&f, 0, sizeof(f));
	f.type_mask = 1 << HCI_EVENT_PKT;
	f.event_mask[0] = 0xffffffff;
	f.event_mask[1] = 0xffffffff;
	if (setsockopt(fd, SOL_HCI, HCI_FILTER, &f, sizeof(f))) {
		perror("HCI_FILTER");
		return 1;
	}

	if (cmd(fd, OP_READ_BD_ADDR, NULL, 0, rp, sizeof(rp)) >= 7)
		printf("hci%d BD_ADDR %02X:%02X:%02X:%02X:%02X:%02X\n", dev,
		       rp[6], rp[5], rp[4], rp[3], rp[2], rp[1]);
	if (cmd(fd, OP_READ_LOCAL_VERSION, NULL, 0, rp, sizeof(rp)) >= 9)
		printf("hci%d HCI version %u rev 0x%04x LMP %u manufacturer %u subver 0x%04x\n",
		       dev, rp[1], rp[2] | rp[3] << 8, rp[4], rp[5] | rp[6] << 8,
		       rp[7] | rp[8] << 8);

	{
		/* enable LE meta events (incl. advertising reports) */
		uint8_t em[8] = { 0xff, 0xff, 0xfb, 0xff, 0x07, 0xf8, 0xbf, 0x3d };
		uint8_t lem[8] = { 0x1f, 0, 0, 0, 0, 0, 0, 0 };
		/* passive, 10 ms interval/window, public, accept all */
		uint8_t sp[7] = { 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00 };
		uint8_t on[2] = { 0x01, 0x00 }, off[2] = { 0x00, 0x00 };

		cmd(fd, OP_SET_EVENT_MASK, em, sizeof(em), NULL, 0);
		cmd(fd, OP_LE_SET_EVENT_MASK, lem, sizeof(lem), NULL, 0);
		cmd(fd, OP_LE_SET_SCAN_ENABLE, off, sizeof(off), NULL, 0);
		if (cmd(fd, OP_LE_SET_SCAN_PARAMS, sp, sizeof(sp), NULL, 0) < 0 ||
		    cmd(fd, OP_LE_SET_SCAN_ENABLE, on, sizeof(on), NULL, 0) < 0) {
			fprintf(stderr, "LE scan could not be started\n");
			return 1;
		}
		printf("LE scan for %d s...\n", secs);

		p.fd = fd;
		p.events = POLLIN;
		end = time(NULL) + secs;
		while (time(NULL) < end) {
			int n, i, num, off_i;

			if (poll(&p, 1, 500) <= 0)
				continue;
			n = read(fd, buf, sizeof(buf));
			if (n < 5 || buf[0] != HCI_EVENT_PKT ||
			    buf[1] != EVT_LE_META || buf[3] != EVT_LE_ADV_REPORT)
				continue;
			num = buf[4];
			off_i = 5;
			for (i = 0; i < num && off_i + 9 <= n; i++) {
				uint8_t *r = buf + off_i;
				int dlen = r[8];
				int8_t rssi = (int8_t)r[9 + dlen];

				printf("adv %02X:%02X:%02X:%02X:%02X:%02X type %u rssi %d\n",
				       r[7], r[6], r[5], r[4], r[3], r[2], r[0], rssi);
				seen++;
				off_i += 10 + dlen;
			}
		}
		cmd(fd, OP_LE_SET_SCAN_ENABLE, off, sizeof(off), NULL, 0);
	}
	printf("advertising reports: %d\n", seen);
	return seen ? 0 : 2;
}
