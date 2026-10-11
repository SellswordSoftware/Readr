const std = @import("std");
const sound = @import("sound.zig");

pub const Waveform = enum { sine, triangle, noise };
pub const Layer = struct {
    waveform: Waveform = .triangle,
    note: f32 = 65,
    gain: f32 = 0.09,
    attack_ms: u16 = 2,
    duration_ms: u16 = 45,
    sweep: f32 = 0,
};
pub const Step = struct { layers: [2]?Layer };
pub const Preset = struct {
    duration_ms: u16,
    second_at_ms: ?u16 = null,
    steps: [2]Step,
};
const silent = Step{ .layers = .{ null, null } };
fn single(layer: Layer, texture: ?Layer) Preset {
    return .{ .duration_ms = @as(u16, @max(layer.duration_ms, if (texture) |l| l.duration_ms else 0)) + 15, .steps = .{ .{ .layers = .{ layer, texture } }, silent } };
}
fn pair(first: Layer, second: Layer, offset: u16) Preset {
    return .{ .duration_ms = offset + second.duration_ms + 15, .second_at_ms = offset, .steps = .{ .{ .layers = .{ first, null } }, .{ .layers = .{ second, null } } } };
}

/// Gains leave headroom for four simultaneous mono synth layers.
const source_presets = std.EnumArray(sound.Cue, Preset).init(.{
    .ui_tick = single(.{ .note = 78, .gain = 0.06, .duration_ms = 12 }, .{ .waveform = .noise, .gain = 0.015, .duration_ms = 9 }),
    .ui_confirm = single(.{ .note = 70, .gain = 0.10, .duration_ms = 32 }, .{ .waveform = .noise, .gain = 0.025, .duration_ms = 16 }),
    .surface_open = single(.{ .note = 64, .gain = 0.075, .duration_ms = 115, .attack_ms = 7, .sweep = 3 }, .{ .waveform = .noise, .gain = 0.035, .attack_ms = 10, .duration_ms = 95 }),
    .surface_close = single(.{ .note = 62, .gain = 0.065, .duration_ms = 90, .attack_ms = 5, .sweep = -3 }, .{ .waveform = .noise, .gain = 0.03, .attack_ms = 7, .duration_ms = 70 }),
    .page_turn = single(.{ .note = 67, .gain = 0.055, .duration_ms = 75, .sweep = -2 }, .{ .waveform = .noise, .gain = 0.08, .attack_ms = 4, .duration_ms = 90 }),
    .chapter_turn = single(.{ .note = 55, .gain = 0.09, .duration_ms = 135, .sweep = -2 }, .{ .waveform = .noise, .gain = 0.075, .attack_ms = 6, .duration_ms = 145 }),
    .mode_change = pair(.{ .note = 62, .duration_ms = 35 }, .{ .note = 69, .duration_ms = 55 }, 45),
    .play = pair(.{ .note = 67, .gain = 0.07, .duration_ms = 23 }, .{ .note = 74, .gain = 0.08, .duration_ms = 35 }, 28),
    .pause = single(.{ .waveform = .sine, .note = 63, .gain = 0.095, .duration_ms = 50, .sweep = -2 }, null),
    .rewind = single(.{ .note = 72, .gain = 0.075, .duration_ms = 90, .sweep = -7 }, .{ .waveform = .noise, .gain = 0.025, .duration_ms = 65 }),
    .boundary = single(.{ .waveform = .sine, .note = 48, .gain = 0.11, .duration_ms = 50, .sweep = -2 }, null),
    .error_cue = pair(.{ .waveform = .sine, .note = 53, .gain = 0.11, .duration_ms = 65 }, .{ .waveform = .sine, .note = 49, .gain = 0.10, .duration_ms = 90 }, 85),
    .reset_arm = single(.{ .waveform = .sine, .note = 47, .gain = 0.10, .duration_ms = 80 }, null),
    .reset_complete = pair(.{ .note = 50, .gain = 0.12, .duration_ms = 55 }, .{ .note = 43, .gain = 0.12, .duration_ms = 115 }, 65),
});

pub fn get(request: sound.Request) Preset {
    var preset: Preset = undefined;
    getInto(request, &preset);
    return preset;
}

pub fn getInto(request: sound.Request, preset: *Preset) void {
    preset.* = source_presets.get(request.cue);
    if (request.cue == .mode_change and request.direction < 0) {
        const first = preset.steps[0].layers[0].?.note;
        preset.steps[0].layers[0].?.note = preset.steps[1].layers[0].?.note;
        preset.steps[1].layers[0].?.note = first;
    }
    for (&preset.steps) |*step| for (&step.layers) |*layer| {
        if (layer.*) |*voice| {
            voice.gain *= request.gain;
            voice.note += request.pitch;
            if (request.short) {
                voice.duration_ms = @max(8, voice.duration_ms / 2);
                voice.attack_ms = @min(voice.attack_ms, 2);
                // Immediate visual changes should not produce long sweeps.
                voice.sweep = 0;
            }
        }
    };
    if (request.duration_ms) |duration| {
        if (!request.short and (request.cue == .surface_open or request.cue == .surface_close)) {
            const ratio = @as(f32, @floatFromInt(duration)) / @as(f32, @floatFromInt(preset.duration_ms));
            for (&preset.steps[0].layers) |*layer| if (layer.*) |*voice| {
                voice.duration_ms = @intFromFloat(@as(f32, @floatFromInt(voice.duration_ms)) * ratio);
            };
            preset.duration_ms = duration;
        }
    }
    if (request.short) {
        preset.duration_ms = @max(20, preset.duration_ms / 2);
        if (preset.second_at_ms) |offset| preset.second_at_ms = offset / 2;
    }
}

test "all cue presets are short, bounded and have headroom" {
    for (std.enums.values(sound.Cue)) |cue| {
        const preset = get(.{ .cue = cue });
        try std.testing.expect(preset.duration_ms <= 200);
        for (preset.steps) |step| for (step.layers) |layer| {
            if (layer) |voice| {
                try std.testing.expect(voice.gain <= 0.12);
                try std.testing.expect(voice.duration_ms > voice.attack_ms);
            }
        };
        const short = get(.{ .cue = cue, .short = true });
        try std.testing.expect(short.duration_ms <= preset.duration_ms);
    }
}

test "caller-owned preset variants never mutate source definitions" {
    var workspace: Preset = undefined;
    for (std.enums.values(sound.Cue)) |cue| {
        const original = get(.{ .cue = cue });
        getInto(.{ .cue = cue, .short = true, .gain = 0.5, .pitch = -3, .direction = -1 }, &workspace);
        getInto(.{ .cue = cue }, &workspace);
        try std.testing.expectEqualDeep(original, workspace);
    }
}
