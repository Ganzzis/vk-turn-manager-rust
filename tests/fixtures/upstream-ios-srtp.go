// This test is staged inside the pinned upstream iOS Go module by ios-srtp.sh.
package main

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/cacggghp/vk-turn-proxy/pkg/proxy/srtpwrap"
)

func run() error {
	underlay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return err
	}
	defer underlay.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	remote := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 56004}
	conn, err := srtpwrap.Client(ctx, underlay, remote, nil)
	cancel()
	if err != nil {
		return fmt.Errorf("upstream iOS DTLS-SRTP handshake: %w", err)
	}
	defer conn.Close()

	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}
	// A synthetic datagram shaped like a WireGuard handshake initiation.
	// The loopback backend checks it and returns a different datagram.
	request := bytes.Repeat([]byte{0x35}, 148)
	copy(request, []byte{1, 0, 0, 0})
	if _, err := conn.Write(request); err != nil {
		return fmt.Errorf("SRTP uplink: %w", err)
	}
	buffer := make([]byte, 2048)
	n, err := conn.Read(buffer)
	if err != nil {
		return fmt.Errorf("SRTP downlink: %w", err)
	}
	want := bytes.Repeat([]byte{0x79}, 92)
	copy(want, []byte{2, 0, 0, 0})
	if !bytes.Equal(buffer[:n], want) {
		return fmt.Errorf("downlink lost datagram bytes or framing")
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Upstream iOS DTLS-SRTP passed bidirectional UDP datagrams.")
}
