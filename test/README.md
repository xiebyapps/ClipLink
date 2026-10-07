# Offline regression checks

Run all host-side checks using Node.js 18 or later, without a device or network:

```sh
node --test test/*.test.cjs
```

- Text hashing executes the real HashUtil source with a SHA-256 platform stub,
  and compares against Node's standard UTF-8 encoding. Lone surrogates use U+FFFD.
- Polling executes the real controller with virtual timers, including an
  unfinished async callback across background/foreground events.
- Error fixtures execute the page's actual reset/clear methods with virtual
  timers and check the full multiline string survives. The layout check verifies
  the status has its own width and no line limit in the scrollable page.

The helper erases the limited type annotations in the two pure ArkTS modules;
it is not an ArkTS compiler. Run the repository's clean/assembleHap build separately.
These fixtures do not render ArkUI or certify background execution. The error
layout has not been exercised on a physical device.
