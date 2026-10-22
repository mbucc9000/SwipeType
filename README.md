<img src="icon.png" width="80" align="right" alt="">

# SwipeType

Swipe typing for the stock iOS 6 keyboard: slide across a word's letters and lift, with a trail, a word preview and alternatives.

## Features

- Slide across a word's letters and lift. A trail follows your finger and a preview shows the word.
- Hold at the end of a swipe for other words, then slide sideways to pick one.
- Delete right after a swipe removes the whole word.
- Swipe Ticks: a light tap as the word picker opens and moves, at KeyTick's strength.

## How to use

1. Slide across a word's letters and lift to type it.
2. Hold at the end of a swipe, then slide sideways to pick another word.
3. Tap delete right after a swipe to remove the whole word.
4. Tune it in Settings › SwipeType.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and PreferenceLoader (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **SwipeType**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT. The word list is from wordfreq by Robyn Speer, CC BY-SA 4.0 (see NOTICE).
