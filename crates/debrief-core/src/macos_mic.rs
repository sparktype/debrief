// 다른 앱이 마이크 입력을 쓰는 중인지(통화·회의) CoreAudio 프로세스 목록으로 읽는다 — 녹음은 하지 않는다
use std::os::raw::c_void;

#[repr(C)]
struct AudioObjectPropertyAddress {
    selector: u32,
    scope: u32,
    element: u32,
}

#[link(name = "CoreAudio", kind = "framework")]
extern "C" {
    fn AudioObjectGetPropertyDataSize(
        object: u32,
        address: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
    ) -> i32;
    fn AudioObjectGetPropertyData(
        object: u32,
        address: *const AudioObjectPropertyAddress,
        qualifier_size: u32,
        qualifier: *const c_void,
        size: *mut u32,
        data: *mut c_void,
    ) -> i32;
}

pub struct MacosMic;

impl MacosMic {
    const SYSTEM_OBJECT: u32 = 1;
    const SCOPE_GLOBAL: u32 = u32::from_be_bytes(*b"glob");
    /// kAudioHardwarePropertyProcessObjectList (macOS 14.2+)
    const PROCESS_OBJECT_LIST: u32 = u32::from_be_bytes(*b"prs#");
    /// kAudioProcessPropertyIsRunningInput — 메뉴 막대의 주황색 마이크 표시와 같은 신호다.
    const IS_RUNNING_INPUT: u32 = u32::from_be_bytes(*b"piri");

    fn address(selector: u32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress { selector, scope: Self::SCOPE_GLOBAL, element: 0 }
    }

    /// 사용 중이면 `Some(true)`, 아니면 `Some(false)`, 읽을 수 없으면(예: macOS 14.2 미만) `None`.
    pub fn is_in_use() -> Option<bool> {
        let list = Self::address(Self::PROCESS_OBJECT_LIST);
        let mut size: u32 = 0;
        // SAFETY: 주소·출력 포인터는 이 스택 프레임 안에서 유효하고, 크기는 CoreAudio가 채운다.
        let status = unsafe { AudioObjectGetPropertyDataSize(Self::SYSTEM_OBJECT, &list, 0, std::ptr::null(), &mut size) };
        if status != 0 {
            return None;
        }
        let mut processes = vec![0u32; size as usize / std::mem::size_of::<u32>()];
        // SAFETY: 버퍼는 `size` 바이트를 담을 수 있고 CoreAudio는 `size`를 넘겨 쓰지 않는다.
        let status = unsafe {
            AudioObjectGetPropertyData(Self::SYSTEM_OBJECT, &list, 0, std::ptr::null(), &mut size, processes.as_mut_ptr().cast())
        };
        if status != 0 {
            return None;
        }
        processes.truncate(size as usize / std::mem::size_of::<u32>());
        let running_input = Self::address(Self::IS_RUNNING_INPUT);
        Some(processes.iter().any(|&process| {
            let mut value: u32 = 0;
            let mut value_size = std::mem::size_of::<u32>() as u32;
            // SAFETY: 출력은 u32 하나이며 그 크기를 넘긴다.
            let status = unsafe {
                AudioObjectGetPropertyData(process, &running_input, 0, std::ptr::null(), &mut value_size, (&mut value as *mut u32).cast())
            };
            status == 0 && value != 0
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 실제 오디오 시스템을 읽는다. 로컬에서 `cargo test -- --ignored macos_mic`로 확인한다.
    #[test]
    #[ignore]
    fn reads_the_process_input_state_on_this_mac() {
        let state = MacosMic::is_in_use();
        eprintln!("mic in use: {state:?}");
        assert!(state.is_some());
    }
}
