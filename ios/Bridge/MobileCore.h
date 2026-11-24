#ifndef VK_MOBILE_CORE_H
#define VK_MOBILE_CORE_H
#include <stddef.h>
#include <stdint.h>

int32_t vkt_validate(const char *profile);
char *vkt_import(const char *uri);
void vkt_string_free(char *value);
void *vkt_tunnel_new(const char *profile);
void vkt_tunnel_free(void *tunnel);
int32_t vkt_tunnel_ready(void *tunnel);
/* Operations: 0 handshake, 1 IP output, 2 UDP input/drain, 3 timer.
 * Result: 0 no output, 1 UDP datagram, 2 IPv4 packet, -1 invalid invocation.
 * Serialize handle access, use nonoverlapping buffers, and free once. */
int32_t vkt_tunnel_step(void *tunnel, int32_t operation, const uint8_t *input,
                        size_t input_len, uint8_t *output, size_t output_len,
                        size_t *written);
/* The relay is ready for WireGuard datagrams at status 1. The caller still
 * needs to verify the WireGuard handshake before exposing VPN connectivity. */
void *vkt_relay_new(const char *profile);
int32_t vkt_relay_status(void *relay);
int32_t vkt_relay_send(void *relay, const uint8_t *input, size_t length);
size_t vkt_relay_receive(void *relay, uint8_t *output, size_t capacity);
void vkt_relay_free(void *relay);
#endif
