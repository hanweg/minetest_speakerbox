# speakerbox

Speaker nodes that play audio, placed in the world, heard from where they
stand. No client mod, no client build, no second window: the mod pushes the
audio to the connected clients with `core.dynamic_add_media` and starts it on a
clock shared by everyone in earshot.

A speaker reads one of two kinds of source:

* **stream** -- a directory of numbered chunks an encoder is still writing.
  Live: desktop audio, a mic, an Icecast mount. Seamed every few seconds.
* **playlist** -- a directory of whole Ogg Vorbis tracks. One sound per track,
  so no seams inside a track at all, crossfaded into the next one.

A vanilla client from 5.3.0 onwards can hear it. The mod is standalone -- it
depends on nothing, including the rest of this repository -- so the directory
can be copied into any server's `mods/`.

## What it is good for, and what it is not

| | |
|---|---|
| a PA, a radio, a stage rig, a DJ set, a listening room | yes |
| a jukebox playing a folder of music | yes, and seamlessly -- see Playlists |
| ambience and announcements over an area | yes |
| a jam session: several people playing together, live | **no** |

End-to-end latency is one chunk plus the delivery lead -- six to ten seconds
with the defaults, and never below about one second however hard you tune it.
Playing music together needs the round trip under about 30 ms, so that is out
of reach of this transport and of every other one that ends at a vanilla
client. If that is what you want, stream note events instead of audio (send
the notes, let each client play locally cached samples) or put the musicians on
a dedicated low-latency path (JackTrip, Sonobus, Jamulus) and use the world
only for the room.

Nobody beat-matches against a room, so for DJing the latency does not matter.

## How it works

**Chunks.** `core.dynamic_add_media` is the only way audio reaches a vanilla
client at runtime, and it takes whole files. The encoder writes a finished Ogg
Vorbis file every `chunk_seconds`; the mod notices it, pushes it to every
connected client, and throws the server's copy away afterwards
(`ephemeral = true`).

**One clock, not a queue.** Each chunk is pushed as soon as it is finished and
started `lead_seconds` later, at a wall-clock time derived from the stream's
anchor rather than from "when the last chunk ended". Playback is therefore
pinned to a clock: a client whose copy arrived late is started with
`start_time` set to exactly how late it was, so it skips into the stream and
stays on the room's beat instead of trailing it by its own ping. The arithmetic
is in `schedule.lua`, which touches no Luanti API and is covered by
`tests/test_schedule.lua`.

**One loop for three cases.** Chunks are started per player, per speaker, on
every tick while their slot is open. That one loop covers an on-time start, a
late delivery, and a player who walks into range halfway through a chunk, with
no special casing -- and because each start is its own `sound_play`, it is also
what makes per-player mute, per-player volume and room mode possible at all
(`exclude_player` takes a single name, so it could never have done it).

**Speakers are the on switch.** A stream with no speaker pointed at it is not
scanned, pushed or played. Nothing is configured server-side to start a stream:
place a node, name a directory.

## Install

Drop the directory in `mods/` and enable it. In this repository `mods/` is
bind-mounted as the dev world's `worldmods`, so it is enabled already.

The `speaker` privilege is needed to configure a speaker, and it is new, so it
is in nobody's `default_privs`. Either grant it, or -- for a private or dev
server -- set `speakerbox.open_access = true`. The mod says so at startup if it
notices that nobody on the server can possibly have it. For this repository's
dev server, add it to `server/data/conf/luanti.conf`:

```
default_privs = interact,shout,fly,fast,noclip,give,settime,teleport,speaker
```

## Quick start

```bash
# 1. start the server (it creates <world>/speakerbox/live on the way up)
scripts/server-run.sh

# 2. feed it something. Any of:
mods/speakerbox/tools/encode.sh server/data/worlds/testworld/speakerbox/live desktop
mods/speakerbox/tools/encode.sh server/data/worlds/testworld/speakerbox/live loop track.flac
mods/speakerbox/tools/encode.sh server/data/worlds/testworld/speakerbox/live url http://stream.example/live.ogg

# 3. in game
/giveme speakerbox:speaker
# place it, punch it to open the panel, leave the stream as "live"
```

Or skip the encoder entirely: drop music in `mods/speakerbox/playlist/`, run
`tools/playlist.sh` over it, and set the speaker's source to `playlist`.

Sound starts within a chunk or two. `/speaker info` says what is happening;
`/speaker test` pushes one chunk and reports what the engine made of it, which
works even with nobody else connected.

Replaying what this machine is playing -- a video in a browser, a music player
-- has a step-by-step walkthrough under
[Walking through a desktop capture](#walking-through-a-desktop-capture), including
the two things that catch everyone: capturing the wrong output device, and the
game's own sound feeding back into the capture.

## Playlists

For audio that already exists as files, chunking is the wrong shape: a track is
already a finished file, so it can be pushed whole. That is what a playlist
speaker does, and it is better in every way that matters -- one sound per track
means no seams, the exact length is known so the next track is queued a whole
track ahead, and the handover is a real crossfade rather than a patched-over
join.

Drop files in the mod's `playlist/` directory, set a speaker's source to
`playlist`, leave the directory field blank, and that is the whole setup.
Subdirectories are separate playlists: name one in the field to use it.

**Convert first.** Luanti decodes Ogg Vorbis and nothing else, so mp3, m4a,
flac, opus and the audio of an mp4 all need converting, and world-mode speakers
need mono:

```bash
mods/speakerbox/tools/playlist.sh --list     # what is there, what needs doing
mods/speakerbox/tools/playlist.sh            # convert everything in playlist/
```

Each source file gets a `.ogg` of the same basename beside it, so
`01-foo.mp3` becomes `01-foo.ogg` and filename order is still playing order;
the originals can stay where they are, because the mod ignores everything that
is not `.ogg`. Levels across a mixed folder are normalised with one pass of
`loudnorm` so that one track does not arrive twice as loud as the next
(`NORMALIZE=0` to skip it, `CHANNELS=2` for stereo if every speaker on it is in
room mode).

**How it runs.** The next track is pushed as soon as the current one starts, so
delivery has a whole track to finish in -- only the very first track of a
session ever waits. Each track's length is read from the granule position of
its last Ogg page, because there is no callback for a sound ending: the
schedule comes out of the files themselves. A listener who arrives in the
middle of a track is started part-way through it, like any other late arrival.

```
/speaker next            hand over to the queued track now
/speaker info            what is playing, its position, what is queued
/speaker test playlist:  push the next track and report its header
```

Tracks repeat when the playlist wraps, so unlike chunks they are worth caching:
a client's media cache is keyed by content, so the second time round costs
nothing even though the media name is new. That is
`speakerbox.playlist_client_cache`, on by default.

## Streams: live audio

A stream speaker plays a directory of numbered chunks. The mod never opens a
socket and never runs a process -- it only reads finished Ogg Vorbis files --
so something else produces them, and the handoff is the filesystem:

```
desktop audio  |                      00000000.ogg
microphone     |                      00000001.ogg --> speakerbox pushes each
a file         |--> ffmpeg ---------> 00000002.ogg     finished chunk and
Icecast / SRT  |    (segment muxer)   00000003.ogg     starts it on the clock
RTMP / HTTP    |                      chunks.list
```

Everything to do with the network is ffmpeg's half, which is why a DJ anywhere
can broadcast with the tools they already have and the server only has to point
ffmpeg at the mount.

### The contract

`tools/encode.sh` is a convenience, not a requirement. Any producer works that
writes:

* files named `00000000.ogg`, `00000001.ogg`, ... -- eight digits, ascending
* **Ogg Vorbis** (not mp3, not Opus), and **mono** if any speaker on the stream
  is in world mode
* segments of `speakerbox.chunk_seconds` each -- the setting and the producer
  must agree
* some signal that a file is finished, which is `speakerbox.ready_mode`:
  `manifest` appends the name to `chunks.list` when it closes the file (what
  ffmpeg's `-segment_list` does); `lag` assumes the highest-numbered file is
  still open, which works with anything and costs one chunk of latency; `all`
  means the producer renames each file into place when it is done.

Numbering may restart from zero -- a producer restarting is normal and the mod
follows it. Old chunks are the producer's to delete; the bytes are copied when
they are pushed, so removing a file that has already gone out is safe.

### The script

`tools/encode.sh <chunk-dir> <mode> [...]`:

| mode | what it captures |
|---|---|
| `desktop [source]` | this machine's audio **out** -- a browser tab, DJ software, anything |
| `mic [source]` | a microphone or line in |
| `file <path>...` | a file, or several as a playlist |
| `loop <path>` | one file, over and over |
| `url <url>` | an Icecast/HTTP/SRT stream |

Override the shape with the environment: `CHUNK`, `RATE`, `CHANNELS`,
`BITRATE`, `KEEP_MINUTES`. `CHUNK` must match `speakerbox.chunk_seconds`.

Two flags in there are not obvious. `-re` is mandatory for a file: without it
ffmpeg encodes the whole thing at once, the mod finds a hundred finished chunks
and a live stream throws all but the newest away. And `-segment_list` is the
"this chunk is finished" signal that `ready_mode = manifest` reads.

### Walking through a desktop capture

Replaying what your computer is playing -- a video in a browser, a music
player, a game -- start to finish.

**1. Prove the capture can hear it.** Do this before touching the game; it is
the step that saves the evening.

```bash
ffmpeg -f pulse -i @DEFAULT_MONITOR@ -t 3 -af volumedetect -f null - 2>&1 \
    | grep mean_volume
```

Roughly -40 to -15 dB means it is hearing your audio. **-91 dB means
silence**: either nothing is playing, or you are listening to the wrong device
(below).

**2. Start the encoder** and leave it in its own terminal. Ctrl-C stops it.

```bash
tools/encode.sh <world>/speakerbox/live desktop
```

**3. Check chunks are landing.**

```bash
ls -la <world>/speakerbox/live
```

Healthy is several `.ogg` files of similar size, one of them 0 bytes (the one
being written), and `chunks.list` naming all *but* that one. Files older than
`KEEP_MINUTES` are pruned as it goes.

**4. In the game**, place a speaker, punch it, set Source to `stream` and the
directory to the stream's name, and save. `/speaker test` should answer
`vorbis, 1 channel(s)` and say the engine accepted the chunk.

**5. Expect sound within a few seconds**, and read the number carefully,
because two different ones get conflated:

* the **offset** between the desktop and the world is `chunk_seconds +
  lead_seconds`, so 8 s with the defaults. It is constant: what you hear now
  is what the desktop played 8 s ago.
* the delay between *pressing play* and hearing anything is anywhere from
  `lead_seconds` to that, depending on where in the current chunk you pressed
  -- the audio you want has to wait for its chunk to finish filling.

`ready_mode = lag` adds another whole chunk to both. After the first chunk it
is continuous, with a soft seam every chunk. `/speaker info` should show
`pushed` and `started` climbing together and `never heard` at zero.

See [Tuning for a live DJ](#tuning-for-a-live-dj) to get the offset down to
about two seconds.

### Tuning for a live DJ

The offset is `chunk_seconds + lead_seconds` and the floor is one chunk,
because `dynamic_add_media` takes a *file*: the engine hashes it whole,
announces it by that hash and the client fetches it by hash, so nothing can be
sent until it is finished. There is no partial or streaming media transfer in
the protocol. Under one chunk needs an engine change, not a setting.

What you can do is make the chunk small. It costs bandwidth, because every
chunk repeats the Vorbis codebook header -- about 2.7 KB of setup in each file,
whatever its length. Measured on the same 60 seconds of music at mono
22050 Hz, nominal 48 kbit/s:

| `chunk_seconds` | real bitrate | offset with a matched lead |
|---|---|---|
| 6.0 | 51 kbps | ~8 s (the default) |
| 3.0 | 56 kbps | ~4 s |
| 1.5 | 65 kbps | ~2 s |
| 0.75 | 83 kbps | ~1.2 s |

A live setup, which is the lowest worth running:

```
speakerbox.chunk_seconds = 1.5
speakerbox.lead_seconds = 0.5
speakerbox.blend_seconds = 0.06
```

and `CHUNK=1.5` on the encoder to match. The scan interval looks after itself:
it is capped at a sixth of the chunk length, so there is no second knob to
remember.

What you are buying it with, apart from bandwidth: a seam every 1.5 s instead
of every 6, which on music is the thing you will notice first. Client memory is
**not** affected -- that is PCM, two bytes per sample per second of audio,
whatever the chunk length or bitrate.

And consider whether you need it. A DJ monitors their own desk directly, at
zero latency; the offset only matters when somebody in the world is reacting
to the DJ or the DJ is reacting to the room. For a set, two seconds and eight
seconds feel the same. For call-and-response, two is worth having.

### Capturing one application, not everything

Two reasons to want this, and the second one is not optional:

* everything on that sink is captured -- notifications, chat beeps, the lot
* **the game's own output is on that sink too.** On one machine, the sound
  speakerbox plays goes back into the capture, so the stream re-records itself
  every few seconds and stacks echoes into a rising mush.

The fix is a sink that goes nowhere, with only the application you want routed
into it:

```bash
# once
pactl load-module module-null-sink sink_name=speakerbox \
    sink_properties=device.description=speakerbox

# find the application and move it
pactl list sink-inputs | grep -E 'Sink Input|application.name'
pactl move-sink-input <index> speakerbox

# optional: hear it locally too, without it entering the capture
pactl load-module module-loopback source=speakerbox.monitor \
    sink=<your real sink>

# capture that instead of the whole desktop
tools/encode.sh <world>/speakerbox/live desktop speakerbox.monitor
```

`pactl unload-module <name or index>` undoes either module. This is also the
right shape for a DJ booth generally: the booth feeds the world, not the room.

### When it captures silence

`@DEFAULT_MONITOR@` follows the *default* sink. If the application is playing
to a headset or HDMI instead, the default's monitor is silent and so is the
stream. `pactl list short sinks` shows which sink is `RUNNING` and
`pactl list short sink-inputs` shows which sink each application is on; pass
that sink's `.monitor` name as the third argument to `encode.sh`.

### Other platforms

`desktop` and `mic` mode are PulseAudio/PipeWire. Elsewhere, feed the same
ffmpeg output arguments from:

* macOS: BlackHole or Loopback as an output device, then `-f avfoundation -i ":1"`
* Windows: a loopback device (VB-Cable, or `virtual-audio-capturer`), then
  `-f dshow -i audio="..."`

### A DJ who is not on the server

Have them stream to an Icecast mount with whatever they already use (Mixxx,
OBS, butt) and run `encode.sh <dir> url <mount>` on the server. One tool for
the broadcaster, nothing at all for the listeners -- that asymmetry is the
point.

## Speaker modes

| | `world` | `room` |
|---|---|---|
| placement | positional: the client pans and attenuates it | locationless, gain computed here |
| falloff | `1/distance`, fixed by OpenAL | ours: flat to `room_knee`, then eased to silence at the radius |
| channels | **mono only** | mono or stereo |
| cost | one sound per listener | one sound per listener, plus a fade packet when they move |
| good for | a speaker you can walk around and locate | an evenly loud dance floor, zones, a hard edge at a wall |

**World mode chunks must be mono.** OpenAL does not pan a multi-channel buffer,
so a stereo chunk played positionally is not placed at all -- and the client
logs a warning naming the sound, which for unique chunk names means a new line
in every listener's log every few seconds. The mod reads the first chunk's Ogg
header and says so once if it catches you (`oggmeta.lua`).

Positional falloff is steep: reference distance is one node and the model is
inverse-clamped, so ten nodes out is roughly a tenth of the volume. Either put
up several speakers, or use room mode, which exists precisely because `1/d` is
the wrong curve for a room full of people.

## Settings

All in `settingtypes.txt`, so they show up in the settings UI.

| setting | default | |
|---|---|---|
| `speakerbox.playlist_dir` | *(blank)* | blank means the mod's own `playlist/`; absolute is used as given; otherwise relative to the world |
| `speakerbox.playlist_shuffle` | `false` | seeded per run, so the order is stable within a run |
| `speakerbox.playlist_loop` | `true` | start again at the end |
| `speakerbox.track_crossfade` | `1.0` | seconds; also the fade-in of the first track |
| `speakerbox.playlist_rescan` | `10.0` | seconds between re-reading the directory |
| `speakerbox.playlist_client_cache` | `true` | tracks repeat, so caching them pays |
| `speakerbox.default_kind` | `stream` | what a newly placed speaker points at |
| `speakerbox.chunk_dir` | `speakerbox` | inside the world directory, or an absolute path |
| `speakerbox.ready_mode` | `manifest` | `manifest`, `lag` or `all` -- how a finished chunk is recognised |
| `speakerbox.chunk_seconds` | `6.0` | must match the encoder |
| `speakerbox.lead_seconds` | `2.0` | delivery budget; most of the added latency |
| `speakerbox.blend_seconds` | `0.08` | crossfade at each seam; `0` for a gap instead |
| `speakerbox.live` | `true` | skip a backlog to stay near live; off for a playlist |
| `speakerbox.max_backlog` | `2` | chunks allowed to pile up before a live stream skips |
| `speakerbox.scan_interval` | `0.25` | seconds between directory scans |
| `speakerbox.default_stream` | `live` | stream for a new speaker; the one directory created for you |
| `speakerbox.default_mode` | `world` | |
| `speakerbox.default_gain` | `1.0` | |
| `speakerbox.default_radius` | `48` | nodes |
| `speakerbox.room_knee` | `0.6` | fraction of the radius that stays at full volume |
| `speakerbox.max_radius` | `96` | cap without the `server` privilege |
| `speakerbox.client_cache` | `false` | let clients keep chunks on disk |
| `speakerbox.warn_old_clients` | `true` | tell a too-old client once why it is silent |
| `speakerbox.open_access` | `false` | skip the `speaker` privilege check |

## Compatibility

Deliberately wide, because the clients that join a party server are not the one
you tested with.

**Server**

| | needs | without it |
|---|---|---|
| anything at all | 5.5.0, for the table form of `dynamic_add_media` | the node still registers so no world loses blocks; streaming is off and the log says why |
| chunks seekable on arrival | 5.8.0, for `start_time` | a late chunk cannot be skipped into, so listeners drift apart at the seams |
| `client_cache` honoured as sent | 5.12.0 | older servers invert the hint |

**Client** -- protocol numbers from `src/network/networkprotocol.cpp`, where
every bump names the release that shipped it.

| client | protocol | what it hears |
|---|---|---|
| 5.8.0 and later | 43+ | everything, in sync |
| 5.6.1, 5.7.x | 41, 42 | plays, but ignores `start_time`: seams drift by however late a chunk arrives |
| 5.5.x | 40 | as above |
| 5.3.0, 5.4.x | 39 | as above, and chunks are pushed inline over the game channel rather than fetched |
| 5.0.0 - 5.2.x | 37, 38 | **nothing.** The engine skips these clients in `Server::dynamicAddMedia`; the mod tells the player once |

`/speaker info` prints the tier of everyone connected, so there is no guessing
which of them is the one complaining.

## What you cannot tune away

**Client memory.** Decoded audio is kept for the whole session: the client's
sound manager only ever inserts into `m_sound_datas_open` and the streaming
variant caches its decoded buffers with no eviction. Every second of audio you
deliver therefore costs each listener about two bytes per sample, for as long
as they stay connected.

| encoding | per hour of audio, per client |
|---|---|
| mono 22050 Hz (the default) | ~150 MB |
| mono 44100 Hz | ~300 MB |
| stereo 44100 Hz | ~600 MB |

Desktops are fine for a long evening; phones are not. The wire is not the
problem: mono Vorbis at 48 kbit/s is about 6 KB/s per listener.

**Played media cannot be freed, and not only from Lua.** The client's sound
manager has no method that releases loaded sound data -- `step`, `pauseAll`,
`resumeAll`, the listener setters, load, play, stop and fade are its whole
surface -- and the protocol has no opcode for it either: of
`TOCLIENT_MEDIA_PUSH`, `MEDIA`, `ANNOUNCE_MEDIA`, `PLAY_SOUND`, `STOP_SOUND`
and `FADE_SOUND`, none can make a client forget anything. Re-using a media
name does not help: `loadSoundData` refuses a name it already holds, so the old
bytes stay and the new audio is silently never loaded, which is worse than the
leak.

So the levers are:

* **sample rate.** The cost is two bytes per sample per second of audio and
  nothing else, so 22050 is half of 44100 and 11025 is half again. The
  compressed bitrate is irrelevant to it.
* **session length**, and knowing where the ceiling is.
* **a reconnect**, which destroys the sound manager along with the connection.
  `core.request_shutdown(msg, true, delay)` puts a reconnect button in front of
  everyone, which is a blunt but real intermission for a long party.

Freeing it properly is an engine change: an eviction method on the sound
manager and a new packet to drive it.

**Seams.** A chunk boundary is a new sound, and nothing can queue one to begin
sample-accurately where another ends. `blend_seconds` starts each chunk early
and fades the previous one out across the overlap, which turns a click into a
soft blend; longer chunks make the seams rarer at the cost of latency. With
`blend_seconds = 0` you get a clean cut and an audible gap whenever delivery
runs late.

**Latency** is `chunk_seconds + lead_seconds`, plus another `chunk_seconds` if
`ready_mode = lag`.

**Joining mid-chunk.** A player who connects after a chunk was pushed does not
have it and stays silent until the next one -- up to `chunk_seconds`. Walking
into range is different and is handled: the chunk already playing is started
for them part-way through.

**Everybody muted is idle.** With no listener who can hear it, a stream is not
pushed at all and its clock goes cold; the next listener starts from what is
live rather than from a backlog.

## Diagnostics

```
/speaker info          everything: server features, stream state, delivery
                       times, and every connected player's protocol tier
/speaker list          where the speakers are and how they are set
/speaker test [stream] push the newest finished chunk and report what the
                       engine made of it. Needs no other player
/speaker mute | unmute | volume <0-2>      per player
/speaker start | stop <stream>             server privilege
/speaker rescan        forget speakers whose node is gone
```

Symptoms, in the order they actually happen:

| what you see | what it is |
|---|---|
| `no finished chunk` from `/speaker test` | the encoder is not running, or is writing somewhere else, or `ready_mode` does not match how it signals completion |
| `opus` or `unrecognised codec` | Luanti decodes Ogg **Vorbis** only. Re-encode with `-c:a libvorbis` |
| `the engine refused the file` | the path is outside what mods may read, or the name collides. The server log has the reason |
| `pushed` climbing, `started` flat | nothing is in earshot: check the speaker's radius and that players are inside it |
| a playlist says `0 track(s)` | the files are not `.ogg`. Run `tools/playlist.sh` |
| `unreadable` climbing on a playlist | a file is not Ogg Vorbis, or is truncated. The log names it; the playlist steps over it |
| a playlist plays nothing and `next up` says `still fetching` | the first track is still being delivered. A megabyte over the game protocol is not instant; `remote_media` makes it so |
| `never heard` climbing | chunks are expiring before they arrive. Raise `lead_seconds` |
| `resyncs` climbing | the encoder is slower than `chunk_seconds`. Make them match |
| `skipped` climbing | the encoder is faster, or the server stalled. Expected after a lag spike |
| it sounds the same everywhere | a `room` mode speaker, or a stereo chunk in `world` mode |
| a desktop capture piles up echoes | the game's own output is in the capture. Route one application through a null sink -- see *Capturing one application* |

## Tests

```bash
mods/speakerbox/tests/run.sh          # needs only lua5.1, no Luanti, no server
```

`schedule.lua` (the clock and the room curve), `oggmeta.lua` (the Ogg header)
and `source.lua` (which files count as finished) have no Luanti API in them and
are tested directly. `pump.lua` is tested against a stub engine that records
what would have been sent, which is the only practical way to pin things like
"a muted player is not pushed to" or "the outgoing chunk is faded out by
handle" -- live, those are invisible until they are wrong.

## Design notes

Claims above that come from the engine rather than from experiment, with where
to check them (paths relative to a Luanti source tree, read at 5.18.0):

| | |
|---|---|
| Vorbis only | `src/client/sound/ogg_file.h` includes `vorbisfile` and nothing else |
| decoded audio is never freed | `src/client/sound/sound_manager.cpp` inserts into `m_sound_datas_open` and never erases; `sound_constants.h` says "Open sounds are kept forever"; `sound_data.h`'s `SoundDataOpenStream` caches buffers with no eviction |
| stereo is not panned | `src/client/sound/sound_manager.cpp` warns on a positional stereo sound; `playing_sound.cpp` only takes the direct-channels path for position-less ones |
| falloff is 1/d from one node | `sound_singleton.cpp` sets `AL_INVERSE_DISTANCE_CLAMPED`; `playing_sound.cpp` sets `AL_REFERENCE_DISTANCE` to 1 |
| `fade` fades in from silence | `sound_manager.cpp`'s `playSoundGeneric` zeroes the volume and fades to the requested gain, in gain units per second |
| media names cannot be reused | `Server::dynamicAddMedia` refuses a name already in `m_media`, so names come from a counter that only goes up |
| a track's length is in its last page | the Ogg granule position is a sample count; `oggmeta.duration` divides it by the rate from the identification header, and agrees with ffprobe to the millisecond on real files |
| clients below protocol 39 get nothing | `Server::dynamicAddMedia` skips them outright |
| `start_time` is safe to send to old clients | the packet is built once for everyone and a short read is harmless |
| a mod may read the world directory | `ScriptApiSecurity::checkPathInternal` allows all of the world path but `worldmods`, `game` and `.git` |
| ephemeral media is cleaned up server-side | `Server::stepPendingDynMediaCallbacks` deletes the temp file and erases the entry once everyone has it, or after 60 s |
