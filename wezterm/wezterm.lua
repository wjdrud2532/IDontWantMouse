-- ~/.wezterm.lua
-- 크로스플랫폼(macOS / Linux / Windows) 공용 WezTerm 설정.
-- Leader 키(Ctrl+a) 기반이라 어느 OS에서든 동일한 단축키로 화면을 분할/이동한다.
-- tmux의 기본 Leader(Ctrl+b)와 겹치지 않으므로 WezTerm 안에서 tmux도 그대로 쓸 수 있다.

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- ┌──────────────────────────────────────────────┐
-- │ 외관                                          │
-- └──────────────────────────────────────────────┘
config.color_scheme = 'Tokyo Night Storm'
config.font = wezterm.font_with_fallback {
  'JetBrains Mono', -- 설치돼 있으면 사용 (brew install --cask font-jetbrains-mono)
  'Menlo',          -- macOS 기본
  'Consolas',       -- Windows 기본
  'DejaVu Sans Mono',
}
config.font_size = 13.0
config.line_height = 1.05
config.scrollback_lines = 10000
config.window_background_opacity = 1.0  -- 완전 불투명 → 또렷한 단색 배경 (흐림 없음)
config.macos_window_background_blur = 0  -- 블러 끔
-- 전체화면을 macOS 네이티브 방식으로(별도 Space 생성 → Ctrl+방향키로 전환 가능)
config.native_macos_fullscreen_mode = true
config.window_decorations = 'RESIZE'
config.window_padding = { left = 6, right = 6, top = 6, bottom = 4 }
config.adjust_window_size_when_changing_font_size = false

-- 탭 바
config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true

-- pane 사이 경계선 색 강조 (활성/비활성 split line)
config.colors = {
  split = '#ffff66', -- 밝은(연한) 노란색 → 경계선이 또렷하게 보임
}

-- 모든 pane 밝기를 동일하게 유지 (어둡게 처리 끔)
-- → 포커스 구분은 아래 OSC 배경색(초록빛 vs 검정)만으로 한다
config.inactive_pane_hsb = {
  brightness = 1.0,  -- 비활성 pane 밝기 100% (활성과 동일)
  saturation = 1.0,  -- 채도도 동일
}

-- 키 이벤트 로깅 (진단용). 필요할 때만 true 로.
config.debug_key_events = false

-- ┌──────────────────────────────────────────────┐
-- │ 포커스된 pane만 다른 배경색 (OSC 이스케이프)    │
-- │ 활성 pane = ACTIVE_BG(초록), 나머지 = INACTIVE_BG │
-- │ pane:inject_output() 으로 OSC 11(배경) 주입.     │
-- │ ※ 로컬 pane 전용                                 │
-- └──────────────────────────────────────────────┘
local ACTIVE_BG   = '#16301d' -- 활성 pane 배경 (초록빛) ← 포커스 표시
local INACTIVE_BG = '#1a1b26' -- 비활성 pane 배경 (검은 톤)

local last_active = {} -- window_id -> 직전 활성 pane_id (불필요한 재주입 방지)

-- 활성 pane 만 초록, 나머지는 검정으로 배경 갱신. 변화 없으면 아무 일도 안 함.
local function recolor_panes(window)
  local tab = window:active_tab()
  if not tab then return end
  local active = tab:active_pane()
  if not active then return end
  local wid = window:window_id()
  if last_active[wid] == active:pane_id() then return end
  last_active[wid] = active:pane_id()
  for _, info in ipairs(tab:panes_with_info()) do
    local bg = info.is_active and ACTIVE_BG or INACTIVE_BG
    -- OSC 11 ; <color> BEL → 해당 pane 의 기본 배경색 설정
    pcall(function() info.pane:inject_output('\x1b]11;' .. bg .. '\x07') end)
  end
end

-- pane 이동 + 즉시 색칠 → 폴링 지연 없이 키 누르는 즉시 반영(0ms).
-- perform_action 이 비동기여도 recolor_panes 의 가드 덕분에 안전:
--   - 새 pane 이 이미 반영됐으면 즉시 색칠(0ms)
--   - 아직이면 가드가 skip → 아래 backstop 이 곧 맞춰줌 (잘못 칠할 일 없음)
local function nav(direction)
  return wezterm.action_callback(function(window, pane)
    window:perform_action(act.ActivatePaneDirection(direction), pane)
    recolor_panes(window)
  end)
end

-- ┌──────────────────────────────────────────────┐
-- │ 화면 분할 / 이동 키 (Leader = Ctrl+a)         │
-- └──────────────────────────────────────────────┘
config.leader = { key = 'a', mods = 'CTRL', timeout_milliseconds = 1000 }

config.keys = {
  -- 분할:  Ctrl+a 다음 |(좌우)  또는  -(상하)   ※ iTerm2의 ⌘D / ⌘⇧D 대응
  { key = '|',  mods = 'LEADER|SHIFT', action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = '\\', mods = 'LEADER',       action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } },
  { key = '-',  mods = 'LEADER',       action = act.SplitVertical   { domain = 'CurrentPaneDomain' } },

  -- pane 이동: Ctrl+a 다음 h/j/k/l 또는 화살표
  { key = 'h', mods = 'LEADER', action = nav 'Left' },
  { key = 'j', mods = 'LEADER', action = nav 'Down' },
  { key = 'k', mods = 'LEADER', action = nav 'Up' },
  { key = 'l', mods = 'LEADER', action = nav 'Right' },
  { key = 'LeftArrow',  mods = 'LEADER', action = nav 'Left' },
  { key = 'DownArrow',  mods = 'LEADER', action = nav 'Down' },
  { key = 'UpArrow',    mods = 'LEADER', action = nav 'Up' },
  { key = 'RightArrow', mods = 'LEADER', action = nav 'Right' },

  -- pane 크기 조절: Ctrl+a 다음 Shift+H/J/K/L
  { key = 'H', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Left', 5 } },
  { key = 'J', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Down', 5 } },
  { key = 'K', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Up', 5 } },
  { key = 'L', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Right', 5 } },

  -- pane 위치 이동(교환): Ctrl+Shift+A → 라벨 뜨면 바꿀 pane 글자 누르기 (현재 pane과 자리 스왑)
  { key = 'a', mods = 'CTRL|SHIFT', action = act.PaneSelect { mode = 'SwapWithActive' } },

  -- pane 관리
  { key = 'z', mods = 'LEADER', action = act.TogglePaneZoomState },          -- 현재 pane 전체화면 토글
  { key = 'x', mods = 'LEADER', action = act.CloseCurrentPane { confirm = true } },

  -- 탭 관리
  { key = 'c', mods = 'LEADER', action = act.SpawnTab 'CurrentPaneDomain' }, -- 새 탭
  { key = 'n', mods = 'LEADER', action = act.ActivateTabRelative(1) },       -- 다음 탭
  { key = 'p', mods = 'LEADER', action = act.ActivateTabRelative(-1) },      -- 이전 탭
  { key = 'w', mods = 'LEADER', action = act.CloseCurrentTab { confirm = true } },

  -- 숫자로 탭 이동: Ctrl+a 다음 1~9
  { key = '1', mods = 'LEADER', action = act.ActivateTab(0) },
  { key = '2', mods = 'LEADER', action = act.ActivateTab(1) },
  { key = '3', mods = 'LEADER', action = act.ActivateTab(2) },
  { key = '4', mods = 'LEADER', action = act.ActivateTab(3) },
  { key = '5', mods = 'LEADER', action = act.ActivateTab(4) },
  { key = '6', mods = 'LEADER', action = act.ActivateTab(5) },
  { key = '7', mods = 'LEADER', action = act.ActivateTab(6) },
  { key = '8', mods = 'LEADER', action = act.ActivateTab(7) },
  { key = '9', mods = 'LEADER', action = act.ActivateTab(8) },

  -- 기타
  { key = '[', mods = 'LEADER', action = act.ActivateCopyMode },                       -- 스크롤/복사 모드
  { key = 'f', mods = 'LEADER', action = act.Search 'CurrentSelectionOrEmptyString' }, -- 검색

  -- Ctrl+a 를 셸로 그대로 보내기(줄 맨앞 이동 등): Ctrl+a 두 번
  { key = 'a', mods = 'LEADER|CTRL', action = act.SendKey { key = 'a', mods = 'CTRL' } },
}

-- ┌──────────────────────────────────────────────┐
-- │ OS별 직접 단축키 (Leader 없이 바로)            │
-- │ 맥은 CMD, 윈도우/리눅스는 CTRL 으로 자동 분기   │
-- │ 이 파일을 세 OS에서 공유하면 단축키 위치 동일   │
-- └──────────────────────────────────────────────┘
local is_mac = wezterm.target_triple:find('darwin') ~= nil
local MOD = is_mac and 'CMD' or 'CTRL'

-- 분할 생성 (Terminator 기준): SHIFT + CMD/CTRL + E / O
--   E = Split Vertically   → 좌우 배치 (WezTerm SplitHorizontal)
--   O = Split Horizontally → 상하 배치 (WezTerm SplitVertical)
table.insert(config.keys, { key = 'E', mods = 'SHIFT|' .. MOD, action = act.SplitHorizontal { domain = 'CurrentPaneDomain' } }) -- 좌우
table.insert(config.keys, { key = 'O', mods = 'SHIFT|' .. MOD, action = act.SplitVertical   { domain = 'CurrentPaneDomain' } }) -- 상하

-- 단어 단위 이동: OPT(맥)/ALT + ← / → → 셸의 Alt+b / Alt+f 로 변환
table.insert(config.keys, { key = 'LeftArrow',  mods = 'ALT', action = act.SendKey { key = 'b', mods = 'ALT' } })
table.insert(config.keys, { key = 'RightArrow', mods = 'ALT', action = act.SendKey { key = 'f', mods = 'ALT' } })
-- 분할 창 상하 이동: OPT/ALT + ↑ / ↓ (←/→ 는 단어 이동에 쓰므로, 좌우 pane 이동은 LEADER 화살표 이용)
table.insert(config.keys, { key = 'UpArrow',    mods = 'ALT', action = nav 'Up' })
table.insert(config.keys, { key = 'DownArrow',  mods = 'ALT', action = nav 'Down' })

-- 커맨드창 닫기: SHIFT + CMD/CTRL + W
table.insert(config.keys, { key = 'W', mods = 'SHIFT|' .. MOD, action = act.CloseCurrentPane { confirm = true } })

-- 크기 조절: SHIFT + CMD/CTRL + 방향키
table.insert(config.keys, { key = 'LeftArrow',  mods = 'SHIFT|' .. MOD, action = act.AdjustPaneSize { 'Left', 5 } })
table.insert(config.keys, { key = 'RightArrow', mods = 'SHIFT|' .. MOD, action = act.AdjustPaneSize { 'Right', 5 } })
table.insert(config.keys, { key = 'UpArrow',    mods = 'SHIFT|' .. MOD, action = act.AdjustPaneSize { 'Up', 5 } })
table.insert(config.keys, { key = 'DownArrow',  mods = 'SHIFT|' .. MOD, action = act.AdjustPaneSize { 'Down', 5 } })

-- 전체화면 토글 (맥): CTRL + CMD + F  ※ macOS 표준 전체화면 단축키
if is_mac then
  table.insert(config.keys, { key = 'f', mods = 'CTRL|CMD', action = act.ToggleFullScreen })

  -- WezTerm 기본 Ctrl+Shift+방향키 pane 이동도 0ms 색칠되도록 nav 로 덮어씀.
  -- (맥에서만. 리눅스/윈도우는 이 조합이 위에서 AdjustPaneSize 로 쓰여서 제외)
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'CTRL|SHIFT', action = nav 'Left' })
  table.insert(config.keys, { key = 'RightArrow', mods = 'CTRL|SHIFT', action = nav 'Right' })
  table.insert(config.keys, { key = 'UpArrow',    mods = 'CTRL|SHIFT', action = nav 'Up' })
  table.insert(config.keys, { key = 'DownArrow',  mods = 'CTRL|SHIFT', action = nav 'Down' })

  -- 라인 맨 앞/맨 뒤 이동: CMD + ← / → → 셸의 Ctrl+A / Ctrl+E 로 변환
  table.insert(config.keys, { key = 'LeftArrow',  mods = 'CMD', action = act.SendKey { key = 'a', mods = 'CTRL' } })
  table.insert(config.keys, { key = 'RightArrow', mods = 'CMD', action = act.SendKey { key = 'e', mods = 'CTRL' } })
  -- 이전 단어 삭제: CMD + Backspace → 셸의 Alt+Backspace (backward-kill-word)
  table.insert(config.keys, { key = 'Backspace', mods = 'CMD', action = act.SendKey { key = 'Backspace', mods = 'ALT' } })
  -- Home / End 키도 줄 맨 앞/뒤로 이동 (CMD + ← / → 와 동일하게 동작)
  table.insert(config.keys, { key = 'Home', mods = 'NONE', action = act.SendKey { key = 'a', mods = 'CTRL' } })
  table.insert(config.keys, { key = 'End',  mods = 'NONE', action = act.SendKey { key = 'e', mods = 'CTRL' } })
end

-- ┌──────────────────────────────────────────────┐
-- │ Enter 키 관련                                 │
-- └──────────────────────────────────────────────┘
-- Opt(ALT) + Enter 전체화면 기본 동작 제거
table.insert(config.keys, { key = 'Enter', mods = 'ALT', action = act.DisableDefaultAssignment })
-- Shift + Enter → 줄바꿈 문자 전송 (제출 없이 줄바꿈)
table.insert(config.keys, { key = 'Enter', mods = 'SHIFT', action = act.SendString '\n' })

-- ┌──────────────────────────────────────────────┐
-- │ 창 포커스에 따른 테마 전환                      │
-- │ WezTerm 창이 OS 포커스를 받으면 FOCUSED,        │
-- │ 다른 앱/창으로 넘어가면 UNFOCUSED 스킴으로 전환  │
-- │ (같은 창 안의 pane 이동은 inactive_pane_hsb 담당)│
-- └──────────────────────────────────────────────┘
local FOCUSED_SCHEME   = 'Tokyo Night Storm' -- 포커스 받은 창 (= config.color_scheme 와 동일)
local UNFOCUSED_SCHEME  = 'Tokyo Night'       -- 포커스 잃은 창 (더 어두운 변형 → 비활성 티 남)

wezterm.on('window-focus-changed', function(window, pane)
  local overrides = window:get_config_overrides() or {}
  if window:is_focused() then
    overrides.color_scheme = FOCUSED_SCHEME
  else
    overrides.color_scheme = UNFOCUSED_SCHEME
  end
  window:set_config_overrides(overrides)
end)

-- ┌──────────────────────────────────────────────┐
-- │ 포커스 변경 backstop (키보드 이동 외 경로용)    │
-- │ Leader/ALT 키 이동은 위 nav() 가 즉시 처리(0ms). │
-- │ 마우스 클릭·탭 전환·pane 닫기/분할 등 키 이동이  │
-- │ 아닌 경로는 이 폴링이 색을 맞춰준다.             │
-- └──────────────────────────────────────────────┘
config.status_update_interval = 200 -- backstop 폴링 주기(ms). 키 이동은 nav()가 즉시 처리하므로 잦을 필요 없음

wezterm.on('update-status', function(window)
  recolor_panes(window)
end)

return config
