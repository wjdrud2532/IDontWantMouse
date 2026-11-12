//! mouse_key 를 누르고 있는 동안 포인터·휠을 얼마나 옮길지 (백엔드가 8ms 마다 tick 을 부르고 결과를 보낸다).
//! Karabiner 의 x·y 1536 을 기본 속도(초당 1000pt)로, 휠 48 을 초당 1000pt 로 본다(설정의 포인터·휠 속도 %로 바꾼다).
//! 처음 0.15초는 35% 에서 100% 까지 천천히 출발해서 조금씩 옮기기 쉽게 한다.

use crate::rules::MouseKey;
use std::collections::HashMap;

#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub struct Step {
    /// 포인터 이동(정수 픽셀). 오른쪽·아래가 양수.
    pub dx: i32,
    pub dy: i32,
    /// 휠(정수 픽셀). vertical_wheel 이 양수면 아래로 (dy 양수 = 아래)
    pub wheel_x: i32,
    pub wheel_y: i32,
}

pub struct MouseKeys {
    pub pointer_scale: f64,
    pub wheel_scale: f64,
    vectors: HashMap<u32, (MouseKey, f64)>,
    last: Option<f64>,
    move_rest: (f64, f64),
    wheel_rest: (f64, f64),
}

impl Default for MouseKeys {
    fn default() -> Self {
        MouseKeys { pointer_scale: 1.0, wheel_scale: 1.0, vectors: HashMap::new(), last: None, move_rest: (0.0, 0.0), wheel_rest: (0.0, 0.0) }
    }
}

impl MouseKeys {
    pub fn start(&mut self, id: u32, v: MouseKey, now: f64) {
        if self.vectors.is_empty() {
            self.last = Some(now);
        }
        self.vectors.insert(id, (v, now));
    }

    pub fn stop(&mut self, id: u32) {
        self.vectors.remove(&id);
        if self.vectors.is_empty() {
            self.halt();
        }
    }

    pub fn stop_all(&mut self) {
        self.vectors.clear();
        self.halt();
    }

    fn halt(&mut self) {
        self.last = None;
        self.wheel_rest = (0.0, 0.0);
    }

    pub fn running(&self) -> bool {
        !self.vectors.is_empty()
    }

    pub fn tick(&mut self, now: f64) -> Step {
        let Some(last) = self.last else { return Step::default() };
        let dt = (now - last).clamp(0.0, 0.05);
        self.last = Some(now);
        let (mut mx, mut my, mut wx, mut wy) = (0.0, 0.0, 0.0, 0.0);
        for (v, since) in self.vectors.values() {
            let k = v.speed_multiplier.unwrap_or(1.0);
            let ramp = (0.35 + 0.65 * (now - since) / 0.15).min(1.0);
            mx += v.x.unwrap_or(0.0) / 1536.0 * 1000.0 * self.pointer_scale * k * ramp;
            my += v.y.unwrap_or(0.0) / 1536.0 * 1000.0 * self.pointer_scale * k * ramp;
            wy += v.vertical_wheel.unwrap_or(0.0) / 48.0 * 1000.0 * self.wheel_scale * k;
            wx += v.horizontal_wheel.unwrap_or(0.0) / 48.0 * 1000.0 * self.wheel_scale * k;
        }
        let take = |rest: &mut (f64, f64), dx: f64, dy: f64| {
            rest.0 += dx;
            rest.1 += dy;
            let step = (rest.0.trunc(), rest.1.trunc());
            rest.0 -= step.0;
            rest.1 -= step.1;
            (step.0 as i32, step.1 as i32)
        };
        let (dx, dy) = take(&mut self.move_rest, mx * dt, my * dt);
        let (wheel_x, wheel_y) = take(&mut self.wheel_rest, wx * dt, wy * dt);
        Step { dx, dy, wheel_x, wheel_y }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_second_moves_about_430() {
        let mut m = MouseKeys::default();
        m.start(1, MouseKey { x: Some(-1536.0), ..Default::default() }, 0.0);
        let mut total = 0;
        let mut t = 0.0;
        while t < 0.5 {
            t += 0.008;
            total += m.tick(t).dx;
        }
        // 0.5초 × 1000pt/s 에서 처음 0.15초 출발 몫(약 50pt)을 뺀 만큼
        assert!((-470..=-420).contains(&total), "{total}");
        m.stop(1);
        assert_eq!(m.tick(t + 0.1), Step::default());
    }
}
