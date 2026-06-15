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
config.color_scheme = 'Catppuccin Mocha'
config.font = wezterm.font_with_fallback {
  'JetBrains Mono', -- 설치돼 있으면 사용 (brew install --cask font-jetbrains-mono)
  'Menlo',          -- macOS 기본
  'Consolas',       -- Windows 기본
  'DejaVu Sans Mono',
}
config.font_size = 13.0
config.line_height = 1.05
config.scrollback_lines = 10000
config.window_background_opacity = 0.97
config.macos_window_background_blur = 20 -- macOS에서만 효과, 다른 OS는 무시됨
-- 전체화면을 macOS 네이티브 방식으로(별도 Space 생성 → Ctrl+방향키로 전환 가능)
config.native_macos_fullscreen_mode = true
config.window_decorations = 'RESIZE'
config.window_padding = { left = 6, right = 6, top = 6, bottom = 4 }
config.adjust_window_size_when_changing_font_size = false

-- 탭 바
config.use_fancy_tab_bar = true
config.hide_tab_bar_if_only_one_tab = true

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
  { key = 'h', mods = 'LEADER', action = act.ActivatePaneDirection 'Left' },
  { key = 'j', mods = 'LEADER', action = act.ActivatePaneDirection 'Down' },
  { key = 'k', mods = 'LEADER', action = act.ActivatePaneDirection 'Up' },
  { key = 'l', mods = 'LEADER', action = act.ActivatePaneDirection 'Right' },
  { key = 'LeftArrow',  mods = 'LEADER', action = act.ActivatePaneDirection 'Left' },
  { key = 'DownArrow',  mods = 'LEADER', action = act.ActivatePaneDirection 'Down' },
  { key = 'UpArrow',    mods = 'LEADER', action = act.ActivatePaneDirection 'Up' },
  { key = 'RightArrow', mods = 'LEADER', action = act.ActivatePaneDirection 'Right' },

  -- pane 크기 조절: Ctrl+a 다음 Shift+H/J/K/L
  { key = 'H', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Left', 5 } },
  { key = 'J', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Down', 5 } },
  { key = 'K', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Up', 5 } },
  { key = 'L', mods = 'LEADER|SHIFT', action = act.AdjustPaneSize { 'Right', 5 } },

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

-- 분할 창 이동: OPT(맥)/ALT + 방향키
table.insert(config.keys, { key = 'LeftArrow',  mods = 'ALT', action = act.ActivatePaneDirection 'Left' })
table.insert(config.keys, { key = 'RightArrow', mods = 'ALT', action = act.ActivatePaneDirection 'Right' })
table.insert(config.keys, { key = 'UpArrow',    mods = 'ALT', action = act.ActivatePaneDirection 'Up' })
table.insert(config.keys, { key = 'DownArrow',  mods = 'ALT', action = act.ActivatePaneDirection 'Down' })

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
end

return config
