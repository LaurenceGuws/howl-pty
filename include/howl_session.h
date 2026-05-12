#ifndef HOWL_SESSION_H
#define HOWL_SESSION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint8_t howl_session_status_idle(void);
uint8_t howl_session_status_active(void);
uint8_t howl_session_status_stopped(void);
uint8_t howl_session_status_is_valid(uint8_t status);
uint8_t howl_session_status_is_active(uint8_t status);

uint8_t howl_session_control_signal_hangup(void);
uint8_t howl_session_control_signal_interrupt(void);
uint8_t howl_session_control_signal_resize_notify(void);
uint8_t howl_session_control_signal_kill(void);
uint8_t howl_session_control_signal_terminate(void);
uint8_t howl_session_control_signal_is_valid(uint8_t signal);

#ifdef __cplusplus
}
#endif

#endif
