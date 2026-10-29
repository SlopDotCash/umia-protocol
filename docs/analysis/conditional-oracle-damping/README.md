# Conditional oracle damping: backtest on UMIA market 3

Why the conditional oracle's accepted tick moves at most 7 ticks per second (420 ticks,
about 4.3%, per minute) instead of the spot oracle's 4,558 per second.

## The problem

Settlement compares each proposal's time-weighted mean tick over the trading window. A
conditional pool holds a fraction of the anchor, so pushing it to a hundredth of its price costs
a fraction of the venture's value, and in tick space that crash is about 46,000 ticks. Credited
at once, twenty minutes of it at the end of a two-day window move the mean by more than the 2%
threshold: the winner flips or the market resolves to no-op. The spot oracle's slew of 4,558
ticks per second stops single-block spikes and nothing slower.

## The rate

The accepted tick may only approach the pool tick at 7 ticks per second. A crash is credited as
a ramp: after twenty minutes the recorded tick has moved 8,400 ticks, not 46,000, and the mean by
about 30 ticks (the ramp's area, 7 × 1200² / 2 tick-seconds, over the 172,800-second window).
Moving a two-day mean by the 2% threshold takes a hold of about 52 minutes, and 64 on a three-day
market, in the open, with every minute of recovery pulling the recorded tick back. Markets shorter
than a few hours get a faster rate so a doubling still registers within a tenth of the window.

## The data

Every `Swap` event `UmiaMarketCore` emitted for UMIA decision market 3 on Base (48-hour window,
four proposals, 209 trades), read from the chain, with the pool price before and after each
trade. The trades were replayed through the damped oracle at several rates: the recorded tick may
move toward the live tick at most the rate allows, and the settled mean is integrated from the
recorded path exactly as the contract does. `backtest.png` is the result.

## What it shows

| Rate (ticks/min) | One-minute moves above the cap | Share of window the cap was binding | Change to any settled mean |
|---|---|---|---|
| 420 (7 ticks/s, the rate in use) | 0 | 0.1% | none |
| 200 | 6 | 0.3% | none |
| 100 | 21 | 0.5% | none |

The largest real one-minute move was 316 ticks (3.2%), on proposal 8, 84 minutes before close.
At 420 the recorded tick never lags the pool by more than a minute or two and every settled
mean is identical to the undamped one. The replay reproduces the onchain result (winner lead
649 ticks simulated, 654 settled).
