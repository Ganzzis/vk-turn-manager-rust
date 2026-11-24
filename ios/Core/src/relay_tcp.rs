use super::connection_error;
use async_trait::async_trait;
use std::net::SocketAddr;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        tcp::{OwnedReadHalf, OwnedWriteHalf},
        TcpStream,
    },
    sync::Mutex,
};
use util::{Conn, Result};

pub(super) struct TurnTcp {
    read: Mutex<OwnedReadHalf>,
    write: Mutex<OwnedWriteHalf>,
    local: SocketAddr,
    peer: SocketAddr,
}

impl TurnTcp {
    pub(super) async fn connect(peer: SocketAddr) -> Result<Self> {
        Self::from_stream(TcpStream::connect(peer).await?)
    }

    pub(super) fn from_stream(socket: TcpStream) -> Result<Self> {
        let peer = socket.peer_addr()?;
        let local = socket.local_addr()?;
        let (read, write) = socket.into_split();
        Ok(Self {
            read: Mutex::new(read),
            write: Mutex::new(write),
            local,
            peer,
        })
    }
}

fn frame(header: [u8; 4]) -> Result<(usize, usize)> {
    let length = usize::from(u16::from_be_bytes([header[2], header[3]]));
    match header[0] >> 6 {
        0 if length % 4 == 0 => Ok((20 + length, 0)),
        1 => Ok((4 + length, (4 - length % 4) % 4)),
        _ => Err(connection_error("Invalid TURN TCP frame")),
    }
}

#[async_trait]
impl Conn for TurnTcp {
    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
    async fn connect(&self, peer: SocketAddr) -> Result<()> {
        if peer == self.peer {
            Ok(())
        } else {
            Err(connection_error("Wrong TURN TCP peer"))
        }
    }
    async fn recv(&self, buffer: &mut [u8]) -> Result<usize> {
        let mut read = self.read.lock().await;
        let mut header = [0; 4];
        read.read_exact(&mut header).await?;
        let (length, padding) = frame(header)?;
        if length > buffer.len() {
            return Err(connection_error("TURN TCP frame too large"));
        }
        buffer[..4].copy_from_slice(&header);
        read.read_exact(&mut buffer[4..length]).await?;
        read.read_exact(&mut [0; 3][..padding]).await?;
        Ok(length)
    }
    async fn recv_from(&self, buffer: &mut [u8]) -> Result<(usize, SocketAddr)> {
        Ok((self.recv(buffer).await?, self.peer))
    }
    async fn send(&self, buffer: &[u8]) -> Result<usize> {
        let header = buffer
            .get(..4)
            .ok_or_else(|| connection_error("Short TURN TCP frame"))?;
        let (length, padding) = frame(header.try_into().unwrap())?;
        if buffer.len() != length && buffer.len() != length + padding {
            return Err(connection_error("Invalid TURN TCP length"));
        }
        let mut write = self.write.lock().await;
        write.write_all(&buffer[..length]).await?;
        write.write_all(&[0; 3][..padding]).await?;
        Ok(buffer.len())
    }
    async fn send_to(&self, buffer: &[u8], peer: SocketAddr) -> Result<usize> {
        self.connect(peer).await?;
        self.send(buffer).await
    }
    fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.local)
    }
    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.peer)
    }
    async fn close(&self) -> Result<()> {
        self.write.lock().await.shutdown().await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn frames_coalesced_stun_and_padded_channel_data() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client = TurnTcp::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut server, _) = listener.accept().await.unwrap();
        let mut bytes = [0u8; 20];
        bytes[..8].copy_from_slice(&[1, 1, 0, 0, 0x21, 0x12, 0xa4, 0x42]);
        let channel = [0x40, 0, 0, 3, 1, 2, 3, 0];
        server
            .write_all(&[bytes.as_slice(), &channel].concat())
            .await
            .unwrap();
        let mut output = [0; 64];
        assert_eq!(client.recv(&mut output).await.unwrap(), 20);
        assert_eq!(output[..20], bytes);
        assert_eq!(client.recv(&mut output).await.unwrap(), 7);
        assert_eq!(output[..7], channel[..7]);
        client.send(&channel[..7]).await.unwrap();
        let mut padded = [0; 8];
        server.read_exact(&mut padded).await.unwrap();
        assert_eq!(padded, channel);
    }
}
