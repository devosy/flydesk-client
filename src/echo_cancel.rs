// fly3-rustdesk-voice: acoustic echo cancellation of the voice call (cargo feature `echo-cancel`).
//
// The engine plays the agent's voice straight to the speakers and sends the raw microphone, so a
// customer on laptop speakers sends the agent's voice back with a delay (rustdesk/rustdesk#16281).
// This module runs WebRTC's AEC3 and noise suppression (`sonora`, a pure-Rust port) on the voice
// path only:
//   - the playback callback (client.rs `build_output_stream`) hands what it just wrote to the
//     speaker to [`push_render`]: the far-end reference, in the output device's format;
//   - the capture encoder thread (audio_service.rs `send_f32`) runs each 10 ms microphone packet
//     through [`process_capture`] before Opus, only while a voice call is on.
// The screen-audio capture (system loopback), the screen, the input and the server are untouched:
// nothing here runs unless [`set_active`] was called with `true` by the voice-call input switch.
//
// The audio processor is owned by the capture thread (one lock, taken there and when the formats
// change); the playback callback only appends to a bounded queue, so it never waits on the AEC.
// Any processing error switches the canceller off for the rest of the call (raw audio goes on).

use hbb_common::log;
use sonora::{
    config::{Config, EchoCanceller, NoiseSuppression},
    AudioProcessing, StreamConfig,
};
use std::{
    collections::VecDeque,
    sync::{
        atomic::{AtomicBool, Ordering},
        Mutex,
    },
};

/// Samples of the far-end kept while the capture thread does not drain them (about half a
/// second at 48 kHz stereo): a bounded queue, never a growing one.
const RENDER_QUEUE_MAX_SAMPLES: usize = 48_000;
const FRAMES_PER_SECOND: usize = 100;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct Format {
    sample_rate: u32,
    channels: u16,
}

impl Format {
    fn frame_samples(&self) -> usize {
        self.sample_rate as usize / FRAMES_PER_SECOND * self.channels as usize
    }
}

struct Render {
    format: Option<Format>,
    samples: VecDeque<f32>,
}

struct Processor {
    apm: AudioProcessing,
    capture: Format,
    render: Format,
    failed: bool,
}

static ACTIVE: AtomicBool = AtomicBool::new(false);
static RENDER: Mutex<Render> = Mutex::new(Render {
    format: None,
    samples: VecDeque::new(),
});
static PROCESSOR: Mutex<Option<Processor>> = Mutex::new(None);

/// The voice call starts (`true`) or ends (`false`): nothing is queued or processed outside it.
pub fn set_active(active: bool) {
    let was = ACTIVE.swap(active, Ordering::AcqRel);
    if was == active {
        return;
    }
    if let Ok(mut r) = RENDER.lock() {
        r.samples.clear();
    }
    if let Ok(mut p) = PROCESSOR.lock() {
        *p = None;
    }
    log::info!("echo cancellation {}", if active { "on" } else { "off" });
}

#[inline]
pub fn is_active() -> bool {
    ACTIVE.load(Ordering::Acquire)
}

/// The output stream was (re)built: what the playback callback pushes from now on has this format.
pub fn set_render_format(sample_rate: u32, channels: u16) {
    let format = Format {
        sample_rate,
        channels,
    };
    if let Ok(mut r) = RENDER.lock() {
        if r.format != Some(format) {
            r.format = Some(format);
            r.samples.clear();
        }
    }
}

/// Far-end reference: interleaved samples just written to the speaker, in the format given to
/// [`set_render_format`]. Called from the audio callback: a bounded push, nothing else.
pub fn push_render(samples: &[f32]) {
    if !is_active() {
        return;
    }
    let Ok(mut r) = RENDER.try_lock() else {
        return;
    };
    if r.format.is_none() {
        return;
    }
    r.samples.extend(samples.iter().copied());
    let excess = r.samples.len().saturating_sub(RENDER_QUEUE_MAX_SAMPLES);
    if excess > 0 {
        r.samples.drain(..excess);
    }
}

/// Near-end: one 10 ms interleaved microphone packet (`sample_rate`, `channels`), replaced in
/// place by the echo-cancelled, noise-suppressed signal. A packet of another size, a missing
/// far-end format or a processing error leaves the packet as it is.
pub fn process_capture(data: &mut [f32], sample_rate: u32, channels: u16) {
    if !is_active() {
        return;
    }
    let capture = Format {
        sample_rate,
        channels,
    };
    if data.len() != capture.frame_samples() || channels == 0 {
        return;
    }
    // Take the far-end frames queued since the last packet (short lock: the callback pushes).
    let (render_format, mut far) = {
        let Ok(mut r) = RENDER.lock() else {
            return;
        };
        let Some(format) = r.format else {
            return;
        };
        let frame = format.frame_samples();
        if frame == 0 {
            return;
        }
        let whole = r.samples.len() / frame * frame;
        let far: Vec<f32> = r.samples.drain(..whole).collect();
        (format, far)
    };
    let Ok(mut guard) = PROCESSOR.lock() else {
        return;
    };
    let rebuild = match guard.as_ref() {
        Some(p) => p.capture != capture || p.render != render_format,
        None => true,
    };
    if rebuild {
        let apm = AudioProcessing::builder()
            .config(Config {
                echo_canceller: Some(EchoCanceller::default()),
                noise_suppression: Some(NoiseSuppression::default()),
                ..Default::default()
            })
            .capture_config(StreamConfig::new(capture.sample_rate as _, capture.channels as _))
            .render_config(StreamConfig::new(
                render_format.sample_rate as _,
                render_format.channels as _,
            ))
            .build();
        *guard = Some(Processor {
            apm,
            capture,
            render: render_format,
            failed: false,
        });
    }
    let Some(p) = guard.as_mut() else {
        return;
    };
    if p.failed {
        return;
    }
    let frame = render_format.frame_samples();
    for chunk in far.chunks_mut(frame) {
        if let Err(e) = process(&mut p.apm, chunk, render_format.channels, true) {
            log::warn!("echo cancellation stopped (far-end): {e:?}");
            p.failed = true;
            return;
        }
    }
    if let Err(e) = process(&mut p.apm, data, channels, false) {
        log::warn!("echo cancellation stopped (capture): {e:?}");
        p.failed = true;
    }
}

// De-interleaves one 10 ms frame, runs it through the render or the capture side, interleaves
// the result back into `data`.
fn process(
    apm: &mut AudioProcessing,
    data: &mut [f32],
    channels: u16,
    render: bool,
) -> Result<(), sonora::Error> {
    let ch = channels as usize;
    let n = data.len() / ch;
    let planar: Vec<Vec<f32>> = (0..ch)
        .map(|c| data.iter().skip(c).step_by(ch).copied().collect())
        .collect();
    let mut out: Vec<Vec<f32>> = vec![vec![0f32; n]; ch];
    {
        let src: Vec<&[f32]> = planar.iter().map(|v| v.as_slice()).collect();
        let mut dest: Vec<&mut [f32]> = out.iter_mut().map(|v| v.as_mut_slice()).collect();
        if render {
            apm.process_render_f32(&src, &mut dest)?;
        } else {
            apm.process_capture_f32(&src, &mut dest)?;
        }
    }
    if !render {
        for (c, channel) in out.iter().enumerate() {
            for (i, s) in channel.iter().enumerate() {
                data[i * ch + c] = *s;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // The module state is global: the tests run one at a time.
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn inactive_canceller_touches_nothing() {
        let _t = TEST_LOCK.lock().unwrap();
        set_active(false);
        set_render_format(48_000, 1);
        push_render(&[0.5; 480]);
        let mut data = vec![0.25f32; 480];
        process_capture(&mut data, 48_000, 1);
        assert!(data.iter().all(|s| *s == 0.25));
        assert!(RENDER.lock().unwrap().samples.is_empty());
    }

    #[test]
    fn render_queue_is_bounded_and_processing_keeps_the_packet_size() {
        let _t = TEST_LOCK.lock().unwrap();
        set_active(true);
        set_render_format(48_000, 2);
        for _ in 0..200 {
            push_render(&[0.1; 960]);
        }
        assert!(RENDER.lock().unwrap().samples.len() <= RENDER_QUEUE_MAX_SAMPLES);
        let mut data: Vec<f32> = (0..480).map(|i| ((i as f32) * 0.05).sin() * 0.3).collect();
        process_capture(&mut data, 48_000, 1);
        assert_eq!(data.len(), 480);
        assert!(data.iter().all(|s| s.is_finite()));
        // A packet of the wrong size is left alone.
        let mut odd = vec![0.2f32; 100];
        process_capture(&mut odd, 48_000, 1);
        assert!(odd.iter().all(|s| *s == 0.2));
        set_active(false);
    }
}
