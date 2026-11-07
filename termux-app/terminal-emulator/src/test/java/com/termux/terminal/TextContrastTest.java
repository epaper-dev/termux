package com.termux.terminal;

import junit.framework.TestCase;

/**
 * {@link TextContrast} keeps text colours of programs on the right side of the threshold of Android's "High contrast
 * text": R+G+B below 384 is drawn solid black, anything else white with an outline, which looks hollow on the wrong
 * background.
 */
public class TextContrastTest extends TestCase {

	private static final int WHITE = 0xFFFFFFFF;
	private static final int BLACK = 0xFF000000;

	private static int red(int color) {
		return (color >> 16) & 0xFF;
	}

	private static int green(int color) {
		return (color >> 8) & 0xFF;
	}

	private static int blue(int color) {
		return color & 0xFF;
	}

	private static int rgb(int red, int green, int blue) {
		return 0xFF000000 | (red << 16) | (green << 8) | blue;
	}

	public void testChannelSumIgnoresAlpha() {
		assertEquals(0, TextContrast.channelSum(0xFF000000));
		assertEquals(765, TextContrast.channelSum(0xFFFFFFFF));
		assertEquals(765, TextContrast.channelSum(0x00FFFFFF));
		assertEquals(6, TextContrast.channelSum(0xFF010203));
	}

	public void testLightOrDarkBackground() {
		assertTrue(TextContrast.isLightBackground(WHITE));
		assertTrue(TextContrast.isLightBackground(0xFFE4E4E4));
		assertTrue(TextContrast.isLightBackground(rgb(128, 128, 128))); // 384, the threshold itself
		assertFalse(TextContrast.isLightBackground(rgb(127, 127, 127))); // 381
		assertFalse(TextContrast.isLightBackground(0xFF404040));
		assertFalse(TextContrast.isLightBackground(BLACK));
	}

	/** Claude Code's "thinking" status is a hard-coded grey of 153 to 185: hollow on white. */
	public void testLightGreyOnLightBackgroundIsDarkened() {
		for (int grey = 153; grey <= 185; grey++) {
			int guarded = TextContrast.guard(rgb(grey, grey, grey), WHITE);
			assertTrue("grey " + grey, TextContrast.channelSum(guarded) < TextContrast.THRESHOLD);
			assertEquals(red(guarded), green(guarded));
			assertEquals(green(guarded), blue(guarded));
		}
		assertEquals(rgb(126, 126, 126), TextContrast.guard(rgb(181, 181, 181), WHITE));
	}

	public void testWhiteOnLightBackgroundIsDarkened() {
		assertEquals(rgb(126, 126, 126), TextContrast.guard(WHITE, WHITE));
	}

	public void testDarkTextOnLightBackgroundStaysUnchanged() {
		assertEquals(BLACK, TextContrast.guard(BLACK, WHITE));
		assertEquals(rgb(0x55, 0x55, 0x55), TextContrast.guard(rgb(0x55, 0x55, 0x55), WHITE));
		// sum 380 is the limit and stays
		assertEquals(rgb(127, 127, 126), TextContrast.guard(rgb(127, 127, 126), WHITE));
		// sum 381 does not
		assertTrue(TextContrast.channelSum(TextContrast.guard(rgb(127, 127, 127), WHITE)) <= TextContrast.LIGHT_BACKGROUND_MAX_SUM);
	}

	public void testDarkenedColourKeepsItsHue() {
		int guarded = TextContrast.guard(rgb(255, 128, 0), WHITE);
		assertTrue(red(guarded) > green(guarded));
		assertTrue(green(guarded) > 0);
		assertEquals(0, blue(guarded));
		assertTrue(TextContrast.channelSum(guarded) <= TextContrast.LIGHT_BACKGROUND_MAX_SUM);
	}

	public void testBlackOnDarkBackgroundIsLightened() {
		// 255 * 388 / 765 = 129.3, rounded up
		assertEquals(rgb(130, 130, 130), TextContrast.guard(BLACK, BLACK));
		int guarded = TextContrast.guard(rgb(0x40, 0x40, 0x40), BLACK);
		assertTrue(TextContrast.channelSum(guarded) >= TextContrast.DARK_BACKGROUND_MIN_SUM);
	}

	public void testLightTextOnDarkBackgroundStaysUnchanged() {
		assertEquals(WHITE, TextContrast.guard(WHITE, BLACK));
		assertEquals(rgb(153, 153, 153), TextContrast.guard(rgb(153, 153, 153), BLACK));
		assertEquals(rgb(130, 129, 129), TextContrast.guard(rgb(130, 129, 129), BLACK)); // sum 388 is the limit and stays
	}

	public void testLightenedColourKeepsItsHue() {
		int guarded = TextContrast.guard(rgb(0, 0, 128), BLACK);
		assertTrue(blue(guarded) > red(guarded));
		assertTrue(blue(guarded) > green(guarded));
		assertTrue(TextContrast.channelSum(guarded) >= TextContrast.DARK_BACKGROUND_MIN_SUM);
	}

	/** Every colour ends up on the right side, never moves the wrong way, and guarding twice changes nothing. */
	public void testEveryColourEndsUpOnTheRightSide() {
		int[] steps = {0, 1, 15, 40, 64, 85, 100, 127, 128, 153, 185, 200, 228, 254, 255};
		for (int red : steps) {
			for (int green : steps) {
				for (int blue : steps) {
					int color = rgb(red, green, blue);

					int onLight = TextContrast.guard(color, WHITE);
					assertEquals(0xFF, onLight >>> 24);
					assertTrue("light " + Integer.toHexString(color), TextContrast.channelSum(onLight) < TextContrast.THRESHOLD);
					assertTrue(red(onLight) <= red && green(onLight) <= green && blue(onLight) <= blue);
					assertEquals(onLight, TextContrast.guard(onLight, WHITE));

					int onDark = TextContrast.guard(color, BLACK);
					assertEquals(0xFF, onDark >>> 24);
					assertTrue("dark " + Integer.toHexString(color), TextContrast.channelSum(onDark) >= TextContrast.THRESHOLD);
					assertTrue(red(onDark) >= red && green(onDark) >= green && blue(onDark) >= blue);
					assertEquals(onDark, TextContrast.guard(onDark, BLACK));
				}
			}
		}
	}

	public void testOnlyColoursOfTheProgramAreGuarded() {
		// the 16 colours of the colour scheme, and the default foreground, background and cursor
		for (int index = 0; index < 16; index++) assertFalse("index " + index, TextContrast.isProgramColor(index));
		assertFalse(TextContrast.isProgramColor(TextStyle.COLOR_INDEX_FOREGROUND));
		assertFalse(TextContrast.isProgramColor(TextStyle.COLOR_INDEX_BACKGROUND));
		assertFalse(TextContrast.isProgramColor(TextStyle.COLOR_INDEX_CURSOR));
		// the colour cube and the grey ramp of the 256 colour palette
		assertTrue(TextContrast.isProgramColor(16));
		assertTrue(TextContrast.isProgramColor(244));
		assertTrue(TextContrast.isProgramColor(255));
		// truecolor
		assertTrue(TextContrast.isProgramColor(rgb(153, 153, 153)));
		assertTrue(TextContrast.isProgramColor(BLACK));
		assertTrue(TextContrast.isProgramColor(WHITE));
	}

}
