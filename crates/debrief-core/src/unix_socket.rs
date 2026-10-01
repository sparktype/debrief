// Unix 도메인 소켓 서버/클라이언트 — SpeechRequest를 길이-프리픽스 프레임으로 전송한다
use crate::speech_request::SpeechRequest;
use std::io;
use std::os::unix::io::RawFd;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub enum UnixSocketError {
    PathTooLong,
    UnsafeExistingPath,
    PayloadTooLarge,
    InvalidFrame,
    Rejected,
    Disconnected,
    SystemCall(String, i32),
}

pub struct UnixSocketServer {
    socket_url: PathBuf,
    file_descriptor: RawFd,
    closed: AtomicBool,
}

impl UnixSocketServer {
    pub const MAXIMUM_PAYLOAD_BYTES: usize = 16 * 1024;

    pub fn new(socket_url: PathBuf) -> Result<Self, UnixSocketError> {
        use std::os::unix::fs::PermissionsExt;

        let directory = socket_url.parent().expect("socket url must have a parent directory");
        std::fs::create_dir_all(directory).map_err(|e| UnixSocketError::SystemCall("mkdir".to_string(), e.raw_os_error().unwrap_or(-1)))?;
        std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| UnixSocketError::SystemCall("chmod(dir)".to_string(), e.raw_os_error().unwrap_or(-1)))?;
        Self::remove_stale_socket_if_safe(&socket_url)?;

        // SAFETY: `AF_UNIX`/`SOCK_STREAM` is a well-defined libc call; the returned fd is
        // checked for `-1` immediately below before any further use.
        let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
        if descriptor < 0 {
            return Err(UnixSocketError::SystemCall("socket".to_string(), Self::errno()));
        }

        let result = (|| -> Result<(), UnixSocketError> {
            Self::configure(descriptor)?;
            let address = Self::address_for(&socket_url)?;
            // SAFETY: `address` is a fully-initialized `sockaddr_un` whose size matches the
            // length passed to `bind`; `descriptor` is the socket just created above.
            let bind_result = unsafe {
                libc::bind(
                    descriptor,
                    &address as *const libc::sockaddr_un as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_un>() as u32,
                )
            };
            if bind_result != 0 {
                return Err(UnixSocketError::SystemCall("bind".to_string(), Self::errno()));
            }
            let path_cstr = Self::path_cstring(&socket_url)?;
            // SAFETY: `path_cstr` is a valid null-terminated C string for the lifetime of this call.
            if unsafe { libc::chmod(path_cstr.as_ptr(), 0o600) } != 0 {
                return Err(UnixSocketError::SystemCall("chmod".to_string(), Self::errno()));
            }
            // SAFETY: `descriptor` is a valid, bound socket fd.
            if unsafe { libc::listen(descriptor, 8) } != 0 {
                return Err(UnixSocketError::SystemCall("listen".to_string(), Self::errno()));
            }
            // SAFETY: `descriptor` is a valid socket fd; F_GETFL/F_SETFL are well-defined fcntl ops.
            let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
            if flags < 0 || unsafe { libc::fcntl(descriptor, libc::F_SETFL, flags | libc::O_NONBLOCK) } != 0 {
                return Err(UnixSocketError::SystemCall("fcntl(O_NONBLOCK)".to_string(), Self::errno()));
            }
            Ok(())
        })();

        if let Err(error) = result {
            // SAFETY: `descriptor` was just opened above and not yet handed to anything else.
            unsafe { libc::close(descriptor) };
            Self::unlink(&socket_url);
            return Err(error);
        }

        Ok(UnixSocketServer { socket_url, file_descriptor: descriptor, closed: AtomicBool::new(false) })
    }

    pub fn accept(&self) -> Result<SpeechRequest, UnixSocketError> {
        self.accept_one()
    }

    pub fn request_close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        // SAFETY: `self.file_descriptor` is valid for the lifetime of `self`;
        // shutdown on a listening socket is safe to call from another thread.
        unsafe { libc::shutdown(self.file_descriptor, libc::SHUT_RDWR) };
    }

    fn accept_one(&self) -> Result<SpeechRequest, UnixSocketError> {
        let descriptor = loop {
            // SAFETY: `self.file_descriptor` is a valid, non-blocking listening socket.
            let descriptor = unsafe { libc::accept(self.file_descriptor, std::ptr::null_mut(), std::ptr::null_mut()) };
            if descriptor >= 0 {
                break descriptor;
            }
            let errno = Self::errno();
            if errno == libc::EINTR {
                continue;
            }
            if errno == libc::EAGAIN || errno == libc::EWOULDBLOCK {
                if self.closed.load(Ordering::SeqCst) {
                    return Err(UnixSocketError::Disconnected);
                }
                let mut event = libc::pollfd { fd: self.file_descriptor, events: libc::POLLIN, revents: 0 };
                // SAFETY: `event` is a valid, single-element pollfd array on the stack.
                let result = unsafe { libc::poll(&mut event, 1, 100) };
                if result < 0 && Self::errno() != libc::EINTR {
                    return Err(UnixSocketError::SystemCall("poll".to_string(), Self::errno()));
                }
                continue;
            }
            if self.closed.load(Ordering::SeqCst) {
                return Err(UnixSocketError::Disconnected);
            }
            return Err(UnixSocketError::SystemCall("accept".to_string(), errno));
        };

        let outcome = Self::handle_accepted(descriptor);
        // SAFETY: `descriptor` came from the `accept` call above and is closed exactly once here.
        unsafe { libc::close(descriptor) };
        outcome
    }

    fn handle_accepted(descriptor: RawFd) -> Result<SpeechRequest, UnixSocketError> {
        // SAFETY: `descriptor` is the freshly accepted connection fd; F_GETFL/F_SETFL are
        // well-defined fcntl ops that only touch this fd's flags.
        let accepted_flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
        if accepted_flags < 0 || unsafe { libc::fcntl(descriptor, libc::F_SETFL, accepted_flags & !libc::O_NONBLOCK) } != 0 {
            return Err(UnixSocketError::SystemCall("fcntl(blocking)".to_string(), Self::errno()));
        }
        Self::configure(descriptor)?;

        let result = (|| -> Result<SpeechRequest, UnixSocketError> {
            let header = Self::read_exactly(4, descriptor)?;
            let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
            if length > Self::MAXIMUM_PAYLOAD_BYTES {
                let _ = Self::write_all(&[0x15], descriptor);
                return Err(UnixSocketError::PayloadTooLarge);
            }
            let payload = Self::read_exactly(length, descriptor)?;
            let request: SpeechRequest = Self::decode_speech_request(&payload).ok_or(UnixSocketError::InvalidFrame)?;
            Self::write_all(&[0x06], descriptor)?;
            Ok(request)
        })();

        match result {
            Ok(request) => Ok(request),
            Err(UnixSocketError::PayloadTooLarge) => Err(UnixSocketError::PayloadTooLarge),
            Err(_) => {
                // 클라이언트별 실패(EOF, 읽기 타임아웃, 잘못된 JSON)가 리스너 자체의 죽음처럼 보이면 안 된다.
                let _ = Self::write_all(&[0x15], descriptor);
                Err(UnixSocketError::InvalidFrame)
            }
        }
    }

    fn decode_speech_request(payload: &[u8]) -> Option<SpeechRequest> {
        let value: serde_json::Value = serde_json::from_slice(payload).ok()?;
        let envelope = value.get("envelope")?;
        let envelope = crate::speech_envelope::SpeechEnvelope {
            v: envelope.get("v")?.as_i64()?,
            text: envelope.get("text")?.as_str()?.to_string(),
            voice: envelope.get("voice")?.as_str()?.to_string(),
            speed: envelope.get("speed")?.as_f64()?,
            volume: envelope.get("volume")?.as_f64()?,
        };
        let priority = match value.get("priority").and_then(|v| v.as_str()) {
            Some("subagent") => crate::speech_request::SpeechPriority::Subagent,
            _ => crate::speech_request::SpeechPriority::Main,
        };
        let lane = match value.get("lane").and_then(|v| v.as_str()) {
            Some("work") => crate::speech_lane::SpeechLane::Work,
            _ => crate::speech_lane::SpeechLane::Companion,
        };
        let emotion = match value.get("emotion").and_then(|v| v.as_str()) {
            Some("warm") => crate::speech_emotion::SpeechEmotion::Warm,
            Some("focused") => crate::speech_emotion::SpeechEmotion::Focused,
            Some("concerned") => crate::speech_emotion::SpeechEmotion::Concerned,
            Some("relieved") => crate::speech_emotion::SpeechEmotion::Relieved,
            Some("tired") => crate::speech_emotion::SpeechEmotion::Tired,
            _ => crate::speech_emotion::SpeechEmotion::Neutral,
        };
        let agent_type = value.get("agentType").and_then(|v| v.as_str()).map(|s| s.to_string());
        Some(SpeechRequest { envelope, priority, lane, emotion, agent_type })
    }

    fn encode_speech_request(request: &SpeechRequest) -> Vec<u8> {
        let value = serde_json::json!({
            "envelope": {
                "v": request.envelope.v,
                "text": request.envelope.text,
                "voice": request.envelope.voice,
                "speed": request.envelope.speed,
                "volume": request.envelope.volume,
            },
            "priority": request.priority.as_str(),
            "lane": match request.lane {
                crate::speech_lane::SpeechLane::Companion => "companion",
                crate::speech_lane::SpeechLane::Work => "work",
            },
            "emotion": match request.emotion {
                crate::speech_emotion::SpeechEmotion::Neutral => "neutral",
                crate::speech_emotion::SpeechEmotion::Warm => "warm",
                crate::speech_emotion::SpeechEmotion::Focused => "focused",
                crate::speech_emotion::SpeechEmotion::Concerned => "concerned",
                crate::speech_emotion::SpeechEmotion::Relieved => "relieved",
                crate::speech_emotion::SpeechEmotion::Tired => "tired",
            },
            "agentType": request.agent_type,
        });
        serde_json::to_vec(&value).expect("speech request always serializes")
    }

    fn remove_stale_socket_if_safe(url: &Path) -> Result<(), UnixSocketError> {
        let path_cstr = Self::path_cstring(url)?;
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: `path_cstr` is valid for this call; `info` is a stack-local out-param.
        if unsafe { libc::lstat(path_cstr.as_ptr(), &mut info) } != 0 {
            let errno = Self::errno();
            if errno == libc::ENOENT {
                return Ok(());
            }
            return Err(UnixSocketError::SystemCall("lstat".to_string(), errno));
        }
        // SAFETY: `geteuid` takes no arguments and cannot fail.
        let euid = unsafe { libc::geteuid() };
        if (info.st_mode & libc::S_IFMT) != libc::S_IFSOCK || info.st_uid != euid {
            return Err(UnixSocketError::UnsafeExistingPath);
        }
        // SAFETY: `path_cstr` is valid for this call.
        if unsafe { libc::unlink(path_cstr.as_ptr()) } != 0 {
            return Err(UnixSocketError::SystemCall("unlink".to_string(), Self::errno()));
        }
        Ok(())
    }

    fn address_for(path: &Path) -> Result<libc::sockaddr_un, UnixSocketError> {
        let path_cstr = Self::path_cstring(path)?;
        let bytes = path_cstr.as_bytes_with_nul();
        // SAFETY: zero-initializing a C struct of POD fields is always valid.
        let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        if bytes.len() > address.sun_path.len() {
            return Err(UnixSocketError::PathTooLong);
        }
        address.sun_family = libc::AF_UNIX as libc::sa_family_t;
        for (dest, src) in address.sun_path.iter_mut().zip(bytes.iter()) {
            *dest = *src as libc::c_char;
        }
        Ok(address)
    }

    fn configure(descriptor: RawFd) -> Result<(), UnixSocketError> {
        let mut no_signal: i32 = 1;
        // SAFETY: `descriptor` is a valid socket fd; `no_signal` and `timeout` are
        // stack-local values whose address and size match the option being set.
        if unsafe {
            libc::setsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                &mut no_signal as *mut _ as *mut libc::c_void,
                std::mem::size_of::<i32>() as u32,
            )
        } != 0
        {
            return Err(UnixSocketError::SystemCall("setsockopt(SO_NOSIGPIPE)".to_string(), Self::errno()));
        }
        let mut timeout = libc::timeval { tv_sec: 0, tv_usec: 150_000 };
        for option in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
            // SAFETY: same as above — `timeout` is a valid, correctly-sized stack value.
            if unsafe {
                libc::setsockopt(
                    descriptor,
                    libc::SOL_SOCKET,
                    option,
                    &mut timeout as *mut _ as *mut libc::c_void,
                    std::mem::size_of::<libc::timeval>() as u32,
                )
            } != 0
            {
                return Err(UnixSocketError::SystemCall("setsockopt(timeout)".to_string(), Self::errno()));
            }
        }
        Ok(())
    }

    fn read_exactly(count: usize, descriptor: RawFd) -> Result<Vec<u8>, UnixSocketError> {
        let mut data = vec![0u8; count];
        let mut offset = 0;
        while offset < count {
            // SAFETY: `data[offset..]` is a valid, correctly-sized buffer for `read`.
            let result = unsafe { libc::read(descriptor, data[offset..].as_mut_ptr() as *mut libc::c_void, count - offset) };
            if result > 0 {
                offset += result as usize;
            } else if result == 0 {
                return Err(UnixSocketError::Disconnected);
            } else if Self::errno() != libc::EINTR {
                return Err(UnixSocketError::SystemCall("read".to_string(), Self::errno()));
            }
        }
        Ok(data)
    }

    fn write_all(data: &[u8], descriptor: RawFd) -> Result<(), UnixSocketError> {
        let mut offset = 0;
        while offset < data.len() {
            // SAFETY: `data[offset..]` is a valid, correctly-sized buffer for `write`.
            let result = unsafe { libc::write(descriptor, data[offset..].as_ptr() as *const libc::c_void, data.len() - offset) };
            if result > 0 {
                offset += result as usize;
            } else if result < 0 && Self::errno() != libc::EINTR {
                return Err(UnixSocketError::SystemCall("write".to_string(), Self::errno()));
            }
        }
        Ok(())
    }

    fn unlink(url: &Path) {
        if let Ok(path_cstr) = Self::path_cstring(url) {
            // SAFETY: `path_cstr` is valid for this call; failure is intentionally ignored
            // (best-effort cleanup matching the Swift `deinit`).
            unsafe { libc::unlink(path_cstr.as_ptr()) };
        }
    }

    fn path_cstring(path: &Path) -> Result<std::ffi::CString, UnixSocketError> {
        std::ffi::CString::new(path.as_os_str().to_str().ok_or(UnixSocketError::PathTooLong)?.as_bytes())
            .map_err(|_| UnixSocketError::PathTooLong)
    }

    fn errno() -> i32 {
        io::Error::last_os_error().raw_os_error().unwrap_or(-1)
    }
}

impl Drop for UnixSocketServer {
    fn drop(&mut self) {
        // SAFETY: `self.file_descriptor` is owned by this server and not yet closed.
        unsafe { libc::close(self.file_descriptor) };
        let mut info: libc::stat = unsafe { std::mem::zeroed() };
        if let Ok(path_cstr) = Self::path_cstring(&self.socket_url) {
            // SAFETY: `path_cstr`/`info` are valid for this call.
            let lstat_ok = unsafe { libc::lstat(path_cstr.as_ptr(), &mut info) } == 0;
            // SAFETY: `geteuid` cannot fail.
            if lstat_ok && (info.st_mode & libc::S_IFMT) == libc::S_IFSOCK && info.st_uid == unsafe { libc::geteuid() } {
                Self::unlink(&self.socket_url);
            }
        }
    }
}

// SAFETY: `UnixSocketServer` only exposes `&self` methods that serialize access to the
// socket fd through blocking syscalls and an atomic `closed` flag — matching the Swift
// original's `@unchecked Sendable` with an `NSLock`-guarded `closed` field.
unsafe impl Send for UnixSocketServer {}
unsafe impl Sync for UnixSocketServer {}

pub struct UnixSocketClient {
    socket_url: PathBuf,
}

impl crate::mcp_speak_tool::SpeechSink for UnixSocketClient {
    type Error = UnixSocketError;
    fn submit(&self, request: SpeechRequest) -> Result<(), Self::Error> {
        UnixSocketClient::submit(self, &request)
    }
}

impl UnixSocketClient {
    pub fn new(socket_url: PathBuf) -> Self {
        UnixSocketClient { socket_url }
    }

    pub fn submit(&self, request: &SpeechRequest) -> Result<(), UnixSocketError> {
        let payload = UnixSocketServer::encode_speech_request(request);
        if payload.len() > UnixSocketServer::MAXIMUM_PAYLOAD_BYTES {
            return Err(UnixSocketError::PayloadTooLarge);
        }
        let mut last_error = UnixSocketError::Disconnected;
        for attempt in 0..2 {
            match Self::submit_once(&payload, &self.socket_url) {
                Ok(()) => return Ok(()),
                Err(error) => {
                    last_error = error;
                    if attempt == 0 {
                        std::thread::sleep(Duration::from_micros(20_000));
                    }
                }
            }
        }
        Err(last_error)
    }

    fn submit_once(payload: &[u8], url: &Path) -> Result<(), UnixSocketError> {
        // SAFETY: see UnixSocketServer::new — same well-defined libc socket() call.
        let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
        if descriptor < 0 {
            return Err(UnixSocketError::SystemCall("socket".to_string(), UnixSocketServer::errno()));
        }
        let result = (|| -> Result<(), UnixSocketError> {
            UnixSocketServer::configure(descriptor)?;
            let address = UnixSocketServer::address_for(url)?;
            // SAFETY: `address` is a fully-initialized `sockaddr_un`; `descriptor` is the
            // socket just created above.
            let connect_result = unsafe {
                libc::connect(
                    descriptor,
                    &address as *const libc::sockaddr_un as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_un>() as u32,
                )
            };
            if connect_result != 0 {
                return Err(UnixSocketError::SystemCall("connect".to_string(), UnixSocketServer::errno()));
            }

            let header = (payload.len() as u32).to_be_bytes();
            UnixSocketServer::write_all(&header, descriptor)?;
            UnixSocketServer::write_all(payload, descriptor)?;
            let acknowledgement = UnixSocketServer::read_exactly(1, descriptor)?;
            if acknowledgement.first() != Some(&0x06) {
                return Err(UnixSocketError::Rejected);
            }
            Ok(())
        })();
        // SAFETY: `descriptor` was opened in this function and not shared elsewhere.
        unsafe { libc::close(descriptor) };
        result
    }
}

/// 리슨 소켓은 건강한데 프레임 단위로만 실패하는 클라이언트 오류.
pub fn is_recoverable_accept_error(error: &UnixSocketError) -> bool {
    matches!(error, UnixSocketError::InvalidFrame | UnixSocketError::PayloadTooLarge | UnixSocketError::Rejected)
}

#[derive(Debug, PartialEq)]
pub enum DirectSpeechCommandError {
    Envelope(crate::speech_envelope::EnvelopeError),
    Socket(UnixSocketError),
}

pub struct DirectSpeechCommand;

impl DirectSpeechCommand {
    pub fn submit(
        text: &str,
        voice: &str,
        speed: f64,
        volume: f64,
        priority: crate::speech_request::SpeechPriority,
        home: &Path,
    ) -> Result<(), DirectSpeechCommandError> {
        let envelope = crate::speech_envelope::SpeechEnvelope { v: 1, text: text.to_string(), voice: voice.to_string(), speed, volume };
        envelope.validate().map_err(DirectSpeechCommandError::Envelope)?;
        let request = SpeechRequest {
            envelope,
            priority,
            lane: crate::speech_lane::SpeechLane::Companion,
            emotion: crate::speech_emotion::SpeechEmotion::Neutral,
            agent_type: None,
        };
        let socket_url = crate::paths::DebriefPaths::for_home(home).socket_url;
        UnixSocketClient::new(socket_url).submit(&request).map_err(DirectSpeechCommandError::Socket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speech_emotion::SpeechEmotion;
    use crate::speech_envelope::SpeechEnvelope;
    use crate::speech_lane::SpeechLane;
    use crate::speech_request::SpeechPriority;
    use std::fs;

    fn temporary_directory() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let url = PathBuf::from("/tmp").join(format!("cs-{nanos}-{counter}"));
        fs::create_dir_all(&url).unwrap();
        url
    }

    fn permissions(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn socket_round_trip_uses_user_only_permissions() {
        let directory = temporary_directory();
        let socket_url = directory.join("cache/debrief.sock");
        let server = std::sync::Arc::new(UnixSocketServer::new(socket_url.clone()).unwrap());
        let client = UnixSocketClient::new(socket_url.clone());
        let envelope = SpeechEnvelope { v: 1, text: "완료".to_string(), voice: "F1".to_string(), speed: 0.93, volume: 0.6 };
        let fixture = SpeechRequest { envelope, priority: SpeechPriority::Main, lane: SpeechLane::Companion, emotion: SpeechEmotion::Neutral, agent_type: None };

        let server_clone = server.clone();
        let received = std::thread::spawn(move || server_clone.accept());
        client.submit(&fixture).unwrap();

        assert_eq!(received.join().unwrap().unwrap(), fixture);
        assert_eq!(permissions(&socket_url), 0o600);
        assert_eq!(permissions(socket_url.parent().unwrap()), 0o700);

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn oversized_payload_is_rejected_before_connect() {
        let client = UnixSocketClient::new(PathBuf::from("/tmp/debrief-missing.sock"));
        let request = SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: "x".repeat(20_000), voice: "F1".to_string(), speed: 1.0, volume: 1.0 },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Companion,
            emotion: SpeechEmotion::Neutral,
            agent_type: None,
        };

        let result = client.submit(&request);
        assert_eq!(result, Err(UnixSocketError::PayloadTooLarge));
    }

    #[test]
    fn refuses_to_unlink_an_existing_regular_file() {
        let directory = temporary_directory();
        let socket_url = directory.join("debrief.sock");
        fs::write(&socket_url, "owned data").unwrap();

        let result = UnixSocketServer::new(socket_url.clone());
        assert_eq!(result.err(), Some(UnixSocketError::UnsafeExistingPath));
        assert_eq!(fs::read_to_string(&socket_url).unwrap(), "owned data");

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn unavailable_socket_fails_within_bounded_retry() {
        let directory = temporary_directory();
        let client = UnixSocketClient::new(directory.join("missing.sock"));
        let request = SpeechRequest {
            envelope: SpeechEnvelope { v: 1, text: "x".to_string(), voice: "F1".to_string(), speed: 1.0, volume: 1.0 },
            priority: SpeechPriority::Main,
            lane: SpeechLane::Companion,
            emotion: SpeechEmotion::Neutral,
            agent_type: None,
        };
        let start = std::time::Instant::now();

        let result = client.submit(&request);
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(1));

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn closing_server_unblocks_accept() {
        let directory = temporary_directory();
        let server = std::sync::Arc::new(UnixSocketServer::new(directory.join("debrief.sock")).unwrap());

        let server_clone = server.clone();
        let stopped = std::thread::spawn(move || server_clone.accept().is_err());
        std::thread::sleep(Duration::from_millis(20));
        server.request_close();

        assert!(stopped.join().unwrap());

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn frame_less_client_is_recoverable() {
        for stall_open in [false, true] {
            let directory = temporary_directory();
            let socket_url = directory.join("debrief.sock");
            let server = UnixSocketServer::new(socket_url.clone()).unwrap();

            // SAFETY: standard libc socket creation, checked immediately below.
            let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
            assert!(descriptor >= 0);
            let address = UnixSocketServer::address_for(&socket_url).unwrap();
            // SAFETY: `address` is fully initialized; `descriptor` was just created.
            let connected = unsafe {
                libc::connect(
                    descriptor,
                    &address as *const libc::sockaddr_un as *const libc::sockaddr,
                    std::mem::size_of::<libc::sockaddr_un>() as u32,
                )
            };
            assert_eq!(connected, 0);
            if !stall_open {
                // SAFETY: `descriptor` is a valid, connected socket fd.
                unsafe { libc::shutdown(descriptor, libc::SHUT_WR) };
            }

            let result = server.accept();
            assert!(result.is_err());
            assert!(is_recoverable_accept_error(&result.unwrap_err()));

            // SAFETY: `descriptor` is owned by this test and not shared elsewhere.
            unsafe { libc::close(descriptor) };
            fs::remove_dir_all(&directory).ok();
        }
    }

    #[test]
    fn valid_fields_submit_exactly_once() {
        let directory = temporary_directory();
        let home = directory.join("home");
        fs::create_dir_all(&home).unwrap();
        let socket_url = crate::paths::DebriefPaths::for_home(&home).socket_url;
        let server = std::sync::Arc::new(UnixSocketServer::new(socket_url).unwrap());

        let server_clone = server.clone();
        let received = std::thread::spawn(move || server_clone.accept());
        DirectSpeechCommand::submit("직접 발화", "M1", 1.1, 0.7, SpeechPriority::Main, &home).unwrap();

        let request = received.join().unwrap().unwrap();
        assert_eq!(
            request.envelope,
            SpeechEnvelope { v: 1, text: "직접 발화".to_string(), voice: "M1".to_string(), speed: 1.1, volume: 0.7 }
        );

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn invalid_fields_fail_before_socket_access() {
        let directory = temporary_directory();
        let home = directory.join("home");
        fs::create_dir_all(&home).unwrap();

        let result = DirectSpeechCommand::submit("x", "BAD", 1.0, 1.0, SpeechPriority::Main, &home);
        assert_eq!(
            result,
            Err(DirectSpeechCommandError::Envelope(crate::speech_envelope::EnvelopeError::InvalidVoice))
        );

        fs::remove_dir_all(&directory).ok();
    }

    #[test]
    fn unavailable_daemon_returns_transport_failure() {
        let directory = temporary_directory();
        let home = directory.join("home");
        fs::create_dir_all(&home).unwrap();

        let result = DirectSpeechCommand::submit("x", "F1", 1.0, 1.0, SpeechPriority::Main, &home);
        assert!(result.is_err());

        fs::remove_dir_all(&directory).ok();
    }
}
