const pd = @import("playdate_api_definitions.zig");
const sound = @import("../audio/sound.zig");
const presets = @import("../audio/sound_presets.zig");

pub const InitError = error{ ChannelFailed, FilterFailed, EffectFailed, SynthFailed, LfoFailed, SourceFailed };

pub const Audio = struct {
    api: *const pd.PlaydateSound,
    channel: *pd.SoundChannel,
    filter: *pd.TwoPoleFilter,
    synths: [4]*pd.PDSynth = undefined,
    lfos: [4]*pd.PDSynthLFO = undefined,
    slots: sound.Slots = .{},
    preset_workspace: presets.Preset = undefined,

    pub fn init(api: *const pd.PlaydateSound) InitError!Audio {
        var audio: Audio = undefined;
        try audio.initInPlace(api);
        return audio;
    }

    pub fn initInPlace(self: *Audio, api: *const pd.PlaydateSound) InitError!void {
        const channel = api.channel.newChannel() orelse return error.ChannelFailed;
        errdefer api.channel.freeChannel(channel);
        // SDK 3.1.2 newChannel already registers the channel. addChannel's
        // zero result means "already present", not an allocation failure.
        _ = api.addChannel(channel);
        errdefer _ = api.removeChannel(channel);
        const filter = api.effect.twopolefilter.newFilter() orelse return error.FilterFailed;
        errdefer api.effect.twopolefilter.freeFilter(filter);
        api.effect.twopolefilter.setType(filter, .FilterTypeLowPass);
        api.effect.twopolefilter.setFrequency(filter, 3500);
        api.effect.twopolefilter.setResonance(filter, 0);
        if (api.channel.addEffect(channel, @ptrCast(filter)) == 0) return error.EffectFailed;
        errdefer _ = api.channel.removeEffect(channel, @ptrCast(filter));
        api.channel.setVolume(channel, 1);
        self.* = .{ .api = api, .channel = channel, .filter = filter };
        var count: usize = 0;
        errdefer self.freeVoices(count);
        for (0..4) |i| {
            const synth = api.synth.newSynth() orelse return error.SynthFailed;
            const lfo = api.lfo.newLFO(.kLFOTypeSawtoothUp) orelse {
                api.synth.freeSynth(synth);
                return error.LfoFailed;
            };
            if (api.channel.addSource(channel, synth) == 0) {
                api.lfo.freeLFO(lfo);
                api.synth.freeSynth(synth);
                return error.SourceFailed;
            }
            self.synths[i] = synth;
            self.lfos[i] = lfo;
            count += 1;
        }
    }

    fn freeVoices(self: *Audio, count: usize) void {
        for (0..count) |i| {
            const synth = self.synths[i];
            self.api.synth.stop(synth);
            self.api.synth.setFrequencyModulator(synth, null);
            _ = self.api.channel.removeSource(self.channel, synth);
            self.api.synth.freeSynth(synth);
            self.api.lfo.freeLFO(self.lfos[i]);
        }
    }

    fn stopSlot(self: *Audio, index: usize) void {
        self.api.synth.stop(self.synths[index * 2]);
        self.api.synth.stop(self.synths[index * 2 + 1]);
    }

    pub fn stop(self: *Audio) void {
        self.slots.stop();
        self.stopSlot(0);
        self.stopSlot(1);
    }

    pub fn deinit(self: *Audio) void {
        self.stop();
        self.freeVoices(4);
        _ = self.api.channel.removeEffect(self.channel, @ptrCast(self.filter));
        self.api.effect.twopolefilter.freeFilter(self.filter);
        _ = self.api.removeChannel(self.channel);
        self.api.channel.freeChannel(self.channel);
    }

    pub fn play(self: *Audio, request: sound.Request, now: u32) void {
        presets.getInto(request, &self.preset_workspace);
        const slot = self.slots.admit(request, now, self.preset_workspace.duration_ms) orelse return;
        self.stopSlot(slot);
        self.update(now);
    }

    pub fn update(self: *Audio, now: u32) void {
        for (0..2) |index| {
            const slot = self.slots.items[index] orelse continue;
            presets.getInto(slot.request, &self.preset_workspace);
            const step = self.slots.due(index, now, self.preset_workspace.second_at_ms) orelse {
                if (self.slots.items[index] == null) self.stopSlot(index);
                continue;
            };
            self.stopSlot(index);
            for (self.preset_workspace.steps[step].layers, 0..) |layer, i| {
                if (layer) |voice| self.playLayer(index * 2 + i, voice);
            }
        }
    }

    fn playLayer(self: *Audio, index: usize, layer: presets.Layer) void {
        const synth = self.synths[index];
        const lfo = self.lfos[index];
        const duration = @as(f32, @floatFromInt(layer.duration_ms)) / 1000;
        const api = self.api;
        api.synth.setWaveform(synth, switch (layer.waveform) {
            .sine => .kWaveformSine,
            .triangle => .kWaveformTriangle,
            .noise => .kWaveformNoise,
        });
        api.synth.setAttackTime(synth, @as(f32, @floatFromInt(layer.attack_ms)) / 1000);
        api.synth.setDecayTime(synth, duration * 0.75);
        api.synth.setSustainLevel(synth, 0);
        api.synth.setReleaseTime(synth, 0.01);
        // Four maximum-gain layers sum to 0.72, leaving mixing headroom.
        const gain = layer.gain * 1.5;
        api.synth.setVolume(synth, gain, gain);
        api.synth.setFrequencyModulator(synth, null);
        if (api.synth.getEnvelope(synth)) |envelope| {
            api.envelope.setCurvature(envelope, -0.3);
            api.envelope.setRetrigger(envelope, 1);
        }
        if (layer.sweep != 0) {
            api.lfo.setType(lfo, if (layer.sweep > 0) .kLFOTypeSawtoothUp else .kLFOTypeSawtoothDown);
            api.lfo.setRate(lfo, 1 / duration);
            api.lfo.setCenter(lfo, layer.sweep / 24);
            api.lfo.setDepth(lfo, @abs(layer.sweep) / 24);
            api.lfo.setDelay(lfo, 0, 0);
            api.lfo.setStartPhase(lfo, 0);
            api.lfo.setRetrigger(lfo, 1);
            api.synth.setFrequencyModulator(synth, @ptrCast(lfo));
        }
        api.synth.playMIDINote(synth, layer.note, 1, duration, 0);
    }
};
