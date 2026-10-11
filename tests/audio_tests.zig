const std = @import("std");
const pd = @import("../src/platform/playdate_api_definitions.zig");
const Audio = @import("../src/platform/playdate_audio.zig").Audio;
const sound = @import("../src/audio/sound.zig");

/// Fail each native allocation and registration independently, without a speaker or SDK
/// process.
pub const Fake = struct {
    var calls: usize = 0;
    var fail_at: usize = 0;
    var channels: usize = 0;
    var registered: usize = 0;
    var filters: usize = 0;
    var effects: usize = 0;
    var synths: usize = 0;
    var lfos: usize = 0;
    var sources: usize = 0;
    pub var notes: usize = 0;
    pub var stops: usize = 0;
    var last_note: f32 = 0;
    var api: pd.PlaydateSound = undefined;
    var channel_api: pd.PlaydateSoundChannel = undefined;
    var synth_api: pd.PlaydateSoundSynth = undefined;
    var lfo_api: pd.PlaydateSoundLFO = undefined;
    var effect_api: pd.PlaydateSoundEffect = undefined;
    var filter_api: pd.PlaydateSoundEffectTwopolefilter = undefined;

    fn succeeds() bool {
        calls += 1;
        return calls != fail_at;
    }
    fn newChannel() callconv(.c) ?*pd.SoundChannel {
        if (!succeeds()) return null;
        channels += 1;
        registered += 1;
        return @ptrFromInt(4);
    }
    fn freeChannel(_: ?*pd.SoundChannel) callconv(.c) void {
        channels -= 1;
    }
    fn addChannel(_: ?*pd.SoundChannel) callconv(.c) c_int {
        return 0; // SDK: newChannel has already registered this channel.
    }
    fn removeChannel(_: ?*pd.SoundChannel) callconv(.c) c_int {
        registered -= 1;
        return 1;
    }
    fn addSource(_: ?*pd.SoundChannel, _: ?*pd.SoundSource) callconv(.c) c_int {
        if (!succeeds()) return 0;
        sources += 1;
        return 1;
    }
    fn removeSource(_: ?*pd.SoundChannel, _: ?*pd.SoundSource) callconv(.c) c_int {
        sources -= 1;
        return 1;
    }
    fn addEffect(_: ?*pd.SoundChannel, _: ?*pd.SoundEffect) callconv(.c) c_int {
        if (!succeeds()) return 0;
        effects += 1;
        return 1;
    }
    fn removeEffect(_: ?*pd.SoundChannel, _: ?*pd.SoundEffect) callconv(.c) c_int {
        effects -= 1;
        return 1;
    }
    fn channelVolume(_: ?*pd.SoundChannel, _: f32) callconv(.c) void {}
    fn newFilter() callconv(.c) ?*pd.TwoPoleFilter {
        if (!succeeds()) return null;
        filters += 1;
        return @ptrFromInt(4);
    }
    fn freeFilter(_: ?*pd.TwoPoleFilter) callconv(.c) void {
        filters -= 1;
    }
    fn filterType(_: ?*pd.TwoPoleFilter, _: pd.TwoPoleFilterType) callconv(.c) void {}
    fn filterFloat(_: ?*pd.TwoPoleFilter, _: f32) callconv(.c) void {}
    fn newSynth() callconv(.c) ?*pd.PDSynth {
        if (!succeeds()) return null;
        synths += 1;
        return @ptrFromInt(4);
    }
    fn freeSynth(_: ?*pd.PDSynth) callconv(.c) void {
        synths -= 1;
    }
    fn stop(_: ?*pd.PDSynth) callconv(.c) void {
        stops += 1;
    }
    fn synthMod(_: ?*pd.PDSynth, _: ?*pd.PDSynthSignalValue) callconv(.c) void {}
    fn waveform(_: ?*pd.PDSynth, _: pd.SoundWaveform) callconv(.c) void {}
    fn synthFloat(_: ?*pd.PDSynth, _: f32) callconv(.c) void {}
    fn volume(_: ?*pd.PDSynth, _: f32, _: f32) callconv(.c) void {}
    fn envelope(_: ?*pd.PDSynth) callconv(.c) ?*pd.PDSynthEnvelope {
        return null;
    }
    fn note(_: ?*pd.PDSynth, value: pd.MIDINote, _: f32, _: f32, _: u32) callconv(.c) void {
        notes += 1;
        last_note = value;
    }
    fn newLFO(_: pd.LFOType) callconv(.c) ?*pd.PDSynthLFO {
        if (!succeeds()) return null;
        lfos += 1;
        return @ptrFromInt(4);
    }
    fn freeLFO(_: ?*pd.PDSynthLFO) callconv(.c) void {
        lfos -= 1;
    }
    fn lfoType(_: ?*pd.PDSynthLFO, _: pd.LFOType) callconv(.c) void {}
    fn lfoFloat(_: ?*pd.PDSynthLFO, _: f32) callconv(.c) void {}
    fn lfoDelay(_: ?*pd.PDSynthLFO, _: f32, _: f32) callconv(.c) void {}
    fn lfoInt(_: ?*pd.PDSynthLFO, _: c_int) callconv(.c) void {}

    pub fn setup(failure: usize) *const pd.PlaydateSound {
        calls = 0;
        fail_at = failure;
        channels = 0;
        registered = 0;
        filters = 0;
        effects = 0;
        synths = 0;
        lfos = 0;
        sources = 0;
        notes = 0;
        stops = 0;
        last_note = 0;
        channel_api = undefined;
        channel_api.newChannel = newChannel;
        channel_api.freeChannel = freeChannel;
        channel_api.addSource = addSource;
        channel_api.removeSource = removeSource;
        channel_api.addEffect = addEffect;
        channel_api.removeEffect = removeEffect;
        channel_api.setVolume = channelVolume;
        filter_api = undefined;
        filter_api.newFilter = newFilter;
        filter_api.freeFilter = freeFilter;
        filter_api.setType = filterType;
        filter_api.setFrequency = filterFloat;
        filter_api.setResonance = filterFloat;
        synth_api = undefined;
        synth_api.newSynth = newSynth;
        synth_api.freeSynth = freeSynth;
        synth_api.stop = stop;
        synth_api.setFrequencyModulator = synthMod;
        synth_api.setWaveform = waveform;
        synth_api.setAttackTime = synthFloat;
        synth_api.setDecayTime = synthFloat;
        synth_api.setSustainLevel = synthFloat;
        synth_api.setReleaseTime = synthFloat;
        synth_api.setVolume = volume;
        synth_api.getEnvelope = envelope;
        synth_api.playMIDINote = note;
        lfo_api = undefined;
        lfo_api.newLFO = newLFO;
        lfo_api.freeLFO = freeLFO;
        lfo_api.setType = lfoType;
        lfo_api.setRate = lfoFloat;
        lfo_api.setCenter = lfoFloat;
        lfo_api.setDepth = lfoFloat;
        lfo_api.setDelay = lfoDelay;
        lfo_api.setStartPhase = lfoFloat;
        lfo_api.setRetrigger = lfoInt;
        effect_api = undefined;
        effect_api.twopolefilter = &filter_api;
        api = undefined;
        api.channel = &channel_api;
        api.synth = &synth_api;
        api.lfo = &lfo_api;
        api.effect = &effect_api;
        api.addChannel = addChannel;
        api.removeChannel = removeChannel;
        return &api;
    }
    fn expectNoResources() !void {
        try std.testing.expectEqual(@as(usize, 0), channels + registered + filters + effects + synths + lfos + sources);
    }
};

test "audio unwinds every partial initialization failure" {
    for (1..16) |failure| {
        if (Audio.init(Fake.setup(failure))) |_| return error.ExpectedFailure else |_| {}
        try Fake.expectNoResources();
    }
    var audio = try Audio.init(Fake.setup(0));
    try std.testing.expectEqual(@as(usize, 4), Fake.synths);
    audio.deinit();
    try Fake.expectNoResources();
}

test "native playback respects priority and cancels sequence steps" {
    var audio = try Audio.init(Fake.setup(0));
    defer audio.deinit();
    audio.play(.{ .cue = .page_turn }, 0);
    audio.play(.{ .cue = .chapter_turn }, 0);
    const before = Fake.notes;
    audio.play(.{ .cue = .ui_tick }, 0);
    try std.testing.expectEqual(before, Fake.notes);
    audio.play(.{ .cue = .error_cue }, 0);
    try std.testing.expectEqual(@as(f32, 53), Fake.last_note);
    audio.update(100);
    try std.testing.expectEqual(@as(f32, 49), Fake.last_note);
    audio.stop();
    const stopped = Fake.notes;
    audio.update(200);
    try std.testing.expectEqual(stopped, Fake.notes);
    audio.play(.{ .cue = .mode_change, .direction = -1 }, 300);
    try std.testing.expectEqual(@as(f32, 69), Fake.last_note);
    audio.stop();
    audio.update(400);
    try std.testing.expectEqual(@as(f32, 69), Fake.last_note);
}

test "native playback covers every family and short variant from heap-owned state" {
    const audio = try std.testing.allocator.create(Audio);
    defer std.testing.allocator.destroy(audio);
    try audio.initInPlace(Fake.setup(0));
    defer audio.deinit();
    for (std.enums.values(sound.Cue)) |cue| {
        for ([_]bool{ false, true }) |short| {
            audio.stop();
            const before = Fake.notes;
            audio.play(.{ .cue = cue, .short = short }, 0);
            audio.update(50);
            try std.testing.expect(Fake.notes > before);
        }
    }
}
