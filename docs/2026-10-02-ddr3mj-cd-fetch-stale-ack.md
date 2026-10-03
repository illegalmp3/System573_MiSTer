# ddr3mj: music and arrows freeze mid-song, no previews afterwards -- the CD sector reader took a stale ack

**2026-10-02.** RTL (`rtl/s573_cdimg.v`). Sim: RED -> GREEN, full suite 65/65. Hardware: pending.

## The report

ddr3mj, "Mr. Wonderful": mid-song the music stopped and the arrows froze while the
background kept animating; ~15 s later the game showed CLEARED; back on Select Music
no song preview played, for any song.

## What the log says (`E:\s573mp3.log`, the song is cfg epoch 79, window 0..0x161fb9)

3rd Mix streams the song from the CD into DIO RAM while it plays, one sector per
read, 24 sectors/s, well ahead of playback.

* Up to LBA 56839 every heartbeat has `cd: 24 reads` and `prof: sectors=24` -- the
  fabric's completed fetches equal Main's served reads in every second of the song
  (362 = 362), including the last one (`1 reads` / `sectors=1`).
* From the next second on, for the rest of the log (115 s):
  `cd_fetch=100.x%  sectors=0  ide_acc=0` and `cd: 0 reads ... total 52438`.
  The fabric says a sector fetch is outstanding all the time; Main -- alive, 26,000
  polls/s, worst gap 2-3 ms -- never sees a request; the game never touches the IDE
  registers again (it is waiting for the data interrupt).
* The DIO write pointer stops at `wp=00b5000` (362 sectors). Playback was 29 s behind
  the loader, so the audible freeze comes 29 s later: `decode STALL ... at
  cur=000b4ebe (741054 of 1449913 bytes into the window, 717229 played)`. The MP3
  service did what it should (held at the watermark, lifted it as stale, found no
  frame, rewound). The game gave up (`CFG epoch=80 ... DRAIN OFF via ENABLES`), and
  with the drive dead no preview could load either.

So: not the MP3 service, not the DIO write path (`wfifo=0/1024` throughout). The CD
sector fetch wedged.

## Why

`cd_busy` is `s573_cdimg.sec_busy`. It stays high only in S_REQ or S_STREAM. In S_REQ
`cd_req` (= `sd_rd[1]`) is held high and Main serves it on its next status poll, so
the reader was in S_STREAM with `cd_req` low -- waiting for 1176 words of a transfer
Main never started. The only way into S_STREAM is `cd_ack` sampled high in S_REQ.

`cd_ack` is `sd_ack[1]`, and it is a level, not a pulse: `psx/sys/hps_io.sv` sets it
on the first word of Main's `UIO_SECTOR_RD | ack` transaction and clears it only when
`io_enable` drops (`DisableIO()` in `user_io.cpp`, after `spi_block_write`). It is
therefore high all through a sector transfer and for a moment after its last word --
the word on which `s573_cdimg` goes S_DONE and tells atapi.v the sector is ready.

`s573_cdimg` accepted a `sec_req` in any state and went straight to S_REQ with
`cd_req=1`. If `sd_ack[1]` was still high from the previous transfer, S_REQ saw "the
host accepted" on the next clock, dropped `cd_req` (one clock high -- invisible to a
status poll) and entered S_STREAM for a transfer that would never come. Nothing
times out, and the game does not reset the drive: wedged for good.

Upstream has the guard this module left out. `psx/rtl/cd_top.vhd`, the state machine
`s573_cdimg` says it implements the contract of:

    when SFETCH_DELAY => -- delay ... and wait for HPS ack before new request
       if (cd_hps_ack = '0') then ...  sectorFetchState <= SFETCH_START;

What the log cannot show is how close the fatal request was to the previous
transfer's end (no per-read timestamps; `cdtrace=0`). The state the fabric was left
in is established; the exact timing that produced it is not.

## The fix

A new state, S_ARM, between the request and the wire: `sec_req` latches the LBA and
invalidates the old sector as before, but `cd_req` is raised only once `cd_ack` is
low. Then S_REQ -> S_STREAM on the ack as before. A re-request in the middle of a
transfer is covered by the same guard (the rest of the old transfer is ignored and
the new request goes out when the host is done).

## The bench (`sim/tb_s573_cdimg_ack.v`, `make -C sim s573_cdimg_ack`)

A host that behaves like Main + hps_io: it polls `cd_req`, latches the LBA at the
poll, holds `cd_ack` from the first word until 48 clocks after the last.
[A] plain fetch; [B] the next request 10 clocks after sec_ready, inside the ack
tail; [C] a re-request for another LBA 500 words into a transfer.

Before the fix (job 201) -- the log's signature, reproduced:

    FAIL: ... WEDGED -- sec_ready never came (sec_busy=1 cd_req=0 cd_ack=0, host transfers=2)
    FAIL: [B] the host served 0 transfers for the second request -- it never saw cd_req
    FAIL: [C] re-request mid-transfer: WEDGED ...

After (jobs 202/203): PASS, with s573_cdimg, atapi_cdread, cdboot, gate5_replay and
the whole suite (65 tests) green.

## Scope

Every CD read of every title goes through this reader, so the wedge was possible
anywhere a title reads the disc during play (3rd Mix songs and previews; the ddrs2k
attract-demo loader that went silent on 2026-09-12 is the same path and worth a
second look with this build -- not established as the same cause).

## What to test on the cabinet

ddr3mj: several full credits; previews on Select Music after each. In the log the
song seconds should keep `cd: 24 reads` / `sectors=24`, `cd_fetch` around 1 %, and
never a run of `cd_fetch=100%` with `sectors=0`.
