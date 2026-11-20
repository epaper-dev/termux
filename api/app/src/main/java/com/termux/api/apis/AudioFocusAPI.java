package com.termux.api.apis;

import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.os.Build;
import android.telecom.TelecomManager;

import com.termux.api.TermuxApiReceiver;
import com.termux.api.util.ResultReturner;
import com.termux.shared.logger.Logger;

/**
 * The audio focus for speech that Termux plays itself (the rootbridge reads Claude's answers through PulseAudio, which
 * asks for no focus): while it is held, Android turns other audio (music) down, like for a navigation app.
 *
 *   termux-api AudioFocus --es action request|release|status
 *
 * Prints one word: request: granted, denied or call; release: released, or failed when Android did not let it go;
 * status: held, lost (another app took it), none or call. "call" means a phone or VoIP call is going on (or the phone rings): then no focus is asked for, and the
 * caller should be quiet. The request lives in this process; when Android ends the process, the focus goes with it
 * and status says none.
 */
public class AudioFocusAPI {

    private static final String LOG_TAG = "AudioFocusAPI";

    private static AudioFocusRequest request;          // API 26+: kept, so release can abandon it whatever came after
    private static boolean granted;
    private static volatile boolean lost;

    private static final AudioManager.OnAudioFocusChangeListener LISTENER = change -> {
        if (change < 0) lost = true;                   // a call, or another app that wants the focus
        else if (change == AudioManager.AUDIOFOCUS_GAIN) lost = false;
    };

    public static void onReceive(final TermuxApiReceiver receiver, final Context context, final Intent intent) {
        Logger.logDebug(LOG_TAG, "onReceive");
        final AudioManager audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        final String action = intent.getStringExtra("action");
        final String result;
        synchronized (AudioFocusAPI.class) {
            if ("request".equals(action)) {
                result = request(context, audioManager);
            } else if ("release".equals(action)) {
                result = release(audioManager) ? "released" : "failed";
            } else {
                result = inCall(context, audioManager) ? "call" : !granted ? "none" : lost ? "lost" : "held";
            }
        }
        ResultReturner.returnData(context, intent, out -> out.println(result));
    }

    private static boolean inCall(Context context, AudioManager audioManager) {
        int mode = audioManager.getMode();
        if (mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_IN_COMMUNICATION
            || mode == AudioManager.MODE_RINGTONE) return true;
        // a call that rings silently leaves the mode alone; Telecom knows it (needs READ_PHONE_STATE, else the mode only)
        try {
            TelecomManager telecom = (TelecomManager) context.getSystemService(Context.TELECOM_SERVICE);
            return telecom != null && telecom.isInCall();
        } catch (SecurityException e) {
            return false;
        }
    }

    private static String request(Context context, AudioManager audioManager) {
        if (inCall(context, audioManager)) return "call";
        lost = false;
        int answer;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (request == null) {
                // speech that guides, like a navigation app: other apps are turned down, not paused
                request = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                    .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build())
                    .setOnAudioFocusChangeListener(LISTENER)
                    .build();
            }
            answer = audioManager.requestAudioFocus(request);
        } else {
            answer = audioManager.requestAudioFocus(LISTENER, AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK);
        }
        granted = answer == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        if (granted) return "granted";
        return inCall(context, audioManager) ? "call" : "denied";
    }

    private static boolean release(AudioManager audioManager) {
        // always abandon (also after a denied or interrupted request): Android may still hold an earlier one
        int answer = AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (request != null) answer = audioManager.abandonAudioFocusRequest(request);
        } else {
            answer = audioManager.abandonAudioFocus(LISTENER);
        }
        if (answer != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) return false;
        granted = false;
        lost = false;
        return true;
    }
}
