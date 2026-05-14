#ifndef HOWL_PTY_H
#define HOWL_PTY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct HowlPtySessionOpaque *HowlPtySessionHandle;

typedef enum {
  HOWL_PTY_CALL_OK = 0,
  HOWL_PTY_CALL_MISSING_HANDLE = -1,
  HOWL_PTY_CALL_INVALID_ARGUMENT = -2,
  HOWL_PTY_CALL_FAILED = -3,
} HowlPtyCallStatus;

typedef enum {
  HOWL_PTY_SESSION_IDLE = 0,
  HOWL_PTY_SESSION_ACTIVE = 1,
  HOWL_PTY_SESSION_STOPPED = 2,
} HowlPtySessionStatus;

typedef enum {
  HOWL_PTY_CONTROL_SIGNAL_HANGUP = 1,
  HOWL_PTY_CONTROL_SIGNAL_INTERRUPT = 2,
  HOWL_PTY_CONTROL_SIGNAL_RESIZE_NOTIFY = 3,
  HOWL_PTY_CONTROL_SIGNAL_KILL = 9,
  HOWL_PTY_CONTROL_SIGNAL_TERMINATE = 15,
} HowlPtyControlSignal;

typedef struct {
  int32_t status;
  uint16_t cols;
  uint16_t rows;
  uint8_t session_status;
  uint8_t reserved0;
  uint16_t reserved1;
  uint32_t resize_count;
} HowlPtySnapshot;

typedef struct {
  int32_t status;
  uint8_t had_pending;
  uint8_t has_pending;
  uint8_t wait_readable;
  uint8_t reserved0;
  uint64_t drained;
} HowlPtyOutboundPump;

typedef struct {
  int32_t status;
  uint8_t any_read;
  uint8_t reserved0;
  uint16_t reserved1;
  uint32_t reserved2;
  uint64_t bytes_read;
} HowlPtyReadResult;

HowlPtySessionHandle howl_pty_session_init(
    const uint8_t *shell_ptr,
    size_t shell_len,
    const uint8_t *command_ptr,
    size_t command_len,
    const uint8_t *start_path_ptr,
    size_t start_path_len,
    uint16_t cols,
    uint16_t rows,
    size_t pending_capacity);
void howl_pty_session_deinit(HowlPtySessionHandle handle);
int32_t howl_pty_session_start(HowlPtySessionHandle handle);
void howl_pty_session_stop(HowlPtySessionHandle handle);
HowlPtySnapshot howl_pty_session_snapshot(HowlPtySessionHandle handle);
int32_t howl_pty_session_resize(HowlPtySessionHandle handle, uint16_t cols, uint16_t rows);
int32_t howl_pty_session_publish_signal(HowlPtySessionHandle handle, uint8_t signal);
int32_t howl_pty_session_publish_input(HowlPtySessionHandle handle, const uint8_t *ptr, size_t len);
HowlPtyOutboundPump howl_pty_session_pump_outbound(HowlPtySessionHandle handle, uint8_t woke);
uint64_t howl_pty_session_pending_bytes(HowlPtySessionHandle handle);
uint64_t howl_pty_session_bytes_applied(HowlPtySessionHandle handle);
uint8_t howl_pty_session_wait_readable(HowlPtySessionHandle handle, int32_t timeout_ms);
HowlPtyReadResult howl_pty_session_read(HowlPtySessionHandle handle, uint8_t *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif
