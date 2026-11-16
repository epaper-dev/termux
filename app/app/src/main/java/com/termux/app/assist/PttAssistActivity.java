package com.termux.app.assist;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;

import com.termux.app.TermuxService;
import com.termux.shared.net.uri.UriUtils;
import com.termux.shared.termux.TermuxConstants;
import com.termux.shared.termux.TermuxConstants.TERMUX_APP.TERMUX_SERVICE;

/**
 * Runs {@code ptt toggle} (termux-rootbridge: push to talk for Claude Code's /voice) in the background and closes
 * itself at once. It has no screen. A long press on Home starts it when Termux is the digital assistant of the phone
 * ({@link PttVoiceInteractionService}); apps and launchers that send ACTION_ASSIST reach it directly.
 *
 * A long press is one event, so it toggles: the first one starts talking, the next one stops.
 */
public class PttAssistActivity extends Activity {

    private static final String PTT_PROGRAM = TermuxConstants.TERMUX_BIN_PREFIX_DIR_PATH + "/ptt";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        final Uri pttUri = UriUtils.getFileUri(PTT_PROGRAM);
        final Intent executeIntent = new Intent(TERMUX_SERVICE.ACTION_SERVICE_EXECUTE, pttUri);
        executeIntent.setClass(this, TermuxService.class);
        executeIntent.putExtra(TERMUX_SERVICE.EXTRA_ARGUMENTS, new String[]{"toggle"});
        executeIntent.putExtra(TERMUX_SERVICE.EXTRA_BACKGROUND, true);
        startService(executeIntent);

        finish();
    }
}
