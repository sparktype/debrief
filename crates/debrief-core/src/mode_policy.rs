// 음소거·모드·도우미 토글과 볼륨 상한 정책
use crate::configuration::DebriefConfiguration;
use crate::speech_lane::SpeechLane;
use crate::speech_request::SpeechPriority;

pub struct ModePolicy;

impl ModePolicy {
    /// 재생 가능한 게인을 돌려주거나, 요청을 버려야 하면 `None`을 돌려준다.
    pub fn admit(
        priority: SpeechPriority,
        lane: SpeechLane,
        requested_volume: f64,
        configuration: &DebriefConfiguration,
    ) -> Option<f64> {
        if configuration.muted || !requested_volume.is_finite() {
            return None;
        }

        if matches!(lane, SpeechLane::Companion) && !configuration.companion_enabled {
            return None;
        }

        if matches!(priority, SpeechPriority::Subagent) {
            use crate::configuration::DebriefMode;
            match configuration.mode {
                DebriefMode::Focus | DebriefMode::Quiet | DebriefMode::Night => return None,
                DebriefMode::Normal | DebriefMode::Verbose => {}
            }
        }

        let ceiling = configuration
            .volume_ceilings
            .get(configuration.mode.as_str())
            .copied()
            .or_else(|| DebriefConfiguration::default_volume_ceilings().get(configuration.mode.as_str()).copied())
            .unwrap_or(1.0);

        Some(requested_volume.clamp(0.0, 1.0).min(ceiling.clamp(0.0, 1.0)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::configuration::DebriefMode;

    fn config(mode: DebriefMode, muted: bool) -> DebriefConfiguration {
        DebriefConfiguration { mode, muted, ..Default::default() }
    }

    #[test]
    fn night_caps_main_and_rejects_subagent() {
        let configuration = config(DebriefMode::Night, false);
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.9, &configuration), Some(0.20));
        assert_eq!(ModePolicy::admit(SpeechPriority::Subagent, SpeechLane::Companion, 0.1, &configuration), None);
    }

    #[test]
    fn mute_rejects_everything() {
        let configuration = config(DebriefMode::Verbose, true);
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.8, &configuration), None);
        assert_eq!(ModePolicy::admit(SpeechPriority::Subagent, SpeechLane::Companion, 0.8, &configuration), None);
    }

    #[test]
    fn focused_modes_reject_subagents() {
        for mode in [DebriefMode::Focus, DebriefMode::Quiet, DebriefMode::Night] {
            let configuration = config(mode, false);
            assert_eq!(
                ModePolicy::admit(SpeechPriority::Subagent, SpeechLane::Companion, 0.1, &configuration),
                None
            );
            assert!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.5, &configuration).is_some());
        }
    }

    #[test]
    fn verbose_admits_subagents_and_clamps_gain() {
        let configuration = config(DebriefMode::Verbose, false);
        assert_eq!(ModePolicy::admit(SpeechPriority::Subagent, SpeechLane::Companion, 0.7, &configuration), Some(0.7));
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 1.5, &configuration), Some(1.0));
    }

    #[test]
    fn quiet_ceilings_main_gain() {
        let configuration = config(DebriefMode::Quiet, false);
        assert_eq!(ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 1.0, &configuration), Some(0.45));
    }

    #[test]
    fn companion_disabled_rejects_companion_lane_only() {
        let configuration = DebriefConfiguration { mode: DebriefMode::Normal, muted: false, companion_enabled: false, ..Default::default() };
        assert_eq!(
            ModePolicy::admit(SpeechPriority::Main, SpeechLane::Companion, 0.8, &configuration),
            None
        );
        assert_eq!(
            ModePolicy::admit(SpeechPriority::Main, SpeechLane::Work, 0.8, &configuration),
            Some(0.8)
        );
    }
}
