package com.termux.terminal;

/**
 * <pre>
 * "CSI ? Pm h", DEC Private Mode Set (DECSET)
 * </pre>
 * <p/>
 * and
 * <p/>
 * <pre>
 * "CSI ? Pm l", DEC Private Mode Reset (DECRST)
 * </pre>
 * <p/>
 * controls various aspects of the terminal
 */
public class DecSetTest extends TerminalTestCase {

	/** DECSET 25, DECTCEM, controls visibility of the cursor. */
	public void testEnableDisableCursor() {
		withTerminalSized(3, 3);
		assertTrue("Initially the cursor should be enabled", mTerminal.isCursorEnabled());
		enterString("\033[?25l"); // Disable Cursor (DECTCEM).
		assertFalse(mTerminal.isCursorEnabled());
		enterString("\033[?25h"); // Enable Cursor (DECTCEM).
		assertTrue(mTerminal.isCursorEnabled());

		enterString("\033[?25l"); // Disable Cursor (DECTCEM), again.
		assertFalse(mTerminal.isCursorEnabled());
		mTerminal.reset();
		assertTrue("Resetting the terminal should enable the cursor", mTerminal.isCursorEnabled());

		enterString("\033[?25l");
		assertFalse(mTerminal.isCursorEnabled());
		enterString("\033c"); // RIS resetting should enabled cursor.
		assertTrue(mTerminal.isCursorEnabled());
	}

	/** DECSET 2031 and DSR 996: report of the color scheme (dark or light) and of changes between them. */
	public void testColorSchemeUpdates() {
		withTerminalSized(3, 3);
		// The default background is black: dark.
		assertEnteringStringGivesResponse("\033[?996n", "\033[?997;1n");
		assertEnteringStringGivesResponse("\033[?2031$p", "\033[?2031;2$y");

		// Without DECSET 2031 a change is not reported.
		assertEnteringStringGivesResponse("\033]11;#ffffff\007", "");
		assertEnteringStringGivesResponse("\033[?996n", "\033[?997;2n");
		enterString("\033]111\007");
		mOutput.getOutputAndClear();

		enterString("\033[?2031h");
		assertEnteringStringGivesResponse("\033[?2031$p", "\033[?2031;1$y");
		// Light background: reported once, a second light background is no change.
		assertEnteringStringGivesResponse("\033]11;#ffffff\007", "\033[?997;2n");
		assertEnteringStringGivesResponse("\033]11;#eeeeee\007", "");
		// Back to dark, also through a reset of the colors from outside (new color scheme of the app).
		assertEnteringStringGivesResponse("\033]11;#000000\007", "\033[?997;1n");
		enterString("\033]11;#ffffff\007");
		mOutput.getOutputAndClear();
		mTerminal.mColors.reset();
		mTerminal.onColorSchemeChanged();
		assertEquals("\033[?997;1n", mOutput.getOutputAndClear());
		mTerminal.onColorSchemeChanged();
		assertEquals("", mOutput.getOutputAndClear());

		enterString("\033[?2031l");
		assertEnteringStringGivesResponse("\033]11;#ffffff\007", "");
	}

	/** DECSET 2004, controls bracketed paste mode. */
	public void testBracketedPasteMode() {
		withTerminalSized(3, 3);

		mTerminal.paste("a");
		assertEquals("Pasting 'a' should output 'a' when bracketed paste mode is disabled", "a", mOutput.getOutputAndClear());

		enterString("\033[?2004h"); // Enable bracketed paste mode.
		mTerminal.paste("a");
		assertEquals("Pasting when in bracketed paste mode should be bracketed", "\033[200~a\033[201~", mOutput.getOutputAndClear());

		enterString("\033[?2004l"); // Disable bracketed paste mode.
		mTerminal.paste("a");
		assertEquals("Pasting 'a' should output 'a' when bracketed paste mode is disabled", "a", mOutput.getOutputAndClear());

		enterString("\033[?2004h"); // Enable bracketed paste mode, again.
		mTerminal.paste("a");
		assertEquals("Pasting when in bracketed paste mode again should be bracketed", "\033[200~a\033[201~", mOutput.getOutputAndClear());

		mTerminal.paste("\033ab\033cd\033");
		assertEquals("Pasting an escape character should not input it", "\033[200~abcd\033[201~", mOutput.getOutputAndClear());
		mTerminal.paste("\u0081ab\u0081cd\u009F");
		assertEquals("Pasting C1 control codes should not input it", "\033[200~abcd\033[201~", mOutput.getOutputAndClear());

		mTerminal.reset();
		mTerminal.paste("a");
		assertEquals("Terminal reset() should disable bracketed paste mode", "a", mOutput.getOutputAndClear());
	}

	/** DECSET 7, DECAWM, controls wraparound mode. */
	public void testWrapAroundMode() {
		// Default with wraparound:
		withTerminalSized(3, 3).enterString("abcd").assertLinesAre("abc", "d  ", "   ");
		// With wraparound disabled:
		withTerminalSized(3, 3).enterString("\033[?7labcd").assertLinesAre("abd", "   ", "   ");
		enterString("efg").assertLinesAre("abg", "   ", "   ");
		// Re-enabling wraparound:
		enterString("\033[?7hhij").assertLinesAre("abh", "ij ", "   ");
	}

}
