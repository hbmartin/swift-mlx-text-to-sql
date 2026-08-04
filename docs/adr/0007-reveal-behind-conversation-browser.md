# Reveal-behind conversation browser on iPhone

Status: accepted.

## Context

CREG needs fast access to multiple Conversations without making the current
analysis feel replaced by a separate history screen. A full-screen list or a
standard push transition would lose the spatial relationship between the current
Conversation and its browser. A conventional overlay drawer would put the list
above the chat, contrary to the intended Messages- and ChatGPT-like depth model.

## Decision

The Conversation Browser lives visually behind the foreground chat. The
top-left browser button or a left-edge swipe moves the chat right one-to-one with
the gesture, rounds its leading corners, and dims it slightly to reveal CREG,
Search, New Chat, Recents, and Settings underneath. The transition is
velocity-aware, interruptible, and reversible; selecting a Conversation, tapping
the exposed chat, or swiping back closes it along the same spatial path.

The app preserves the reveal-behind hierarchy in light and dark appearance while
providing functionally equivalent Reduce Motion, Reduce Transparency, VoiceOver,
and keyboard behaviors. Liquid Glass belongs to elevated controls and transient
surfaces, not to the entire browser or transcript.

## Consequences

Conversation switching retains strong spatial continuity and keeps the current
work visibly present. CREG accepts the cost of a custom interactive transition,
including gesture-conflict, accessibility, rotation, keyboard, and state-
restoration testing that a standard navigation container would otherwise supply.
