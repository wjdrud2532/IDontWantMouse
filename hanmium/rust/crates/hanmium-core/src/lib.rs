//! Hanmium 공통 코어. 운영체제 API 를 전혀 쓰지 않아서 맥·리눅스·윈도우 어디서나 같은 시험(`cargo test`)으로 확인한다.
//!
//! - [`keys`]: Karabiner-Elements 의 key_code 이름([`Key`])과 왼쪽·오른쪽을 구분하는 수정키 묶음([`Mods`]).
//!   백엔드가 자기 키 코드(macOS 가상 키 코드, 리눅스 evdev, 윈도우 가상 키)와 서로 바꾼다.
//! - [`rules`]: Karabiner 규칙 JSON 읽기.
//! - [`engine`]: 키 입력 하나에 무엇을 내보낼지 정하는 키보드 규칙 엔진.
//! - [`modsync`]: 이벤트마다 수정키 플래그를 붙일 수 없는 운영체제(리눅스·윈도우)에서 수정키를 실제로 눌렀다 떼서 맞추기.
//! - [`mousekeys`]: mouse_key(포인터·휠)를 누르고 있는 동안 얼마나 옮길지.
//! - [`labels`]: Vimium 방식 라벨 글자.

pub mod engine;
pub mod keys;
pub mod labels;
pub mod modsync;
pub mod mousekeys;
pub mod rules;

pub use engine::{Engine, Output};
pub use keys::{Key, Mods};
