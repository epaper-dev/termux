package com.termux.app.assist;

import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;

/**
 * The assistant was invoked (a long press on Home): toggle push to talk through {@link PttAssistActivity}, which
 * starts the command from a foreground component, and close the session without showing anything.
 */
public class PttVoiceInteractionSession extends VoiceInteractionSession {

    public PttVoiceInteractionSession(Context context) {
        super(context);
    }

    @Override
    public void onShow(Bundle args, int showFlags) {
        super.onShow(args, showFlags);
        // startAssistantActivity needs Android 6; before that the session only closes and there is no assistant to pick
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            startAssistantActivity(new Intent(getContext(), PttAssistActivity.class));
        }
        hide();
    }
}
