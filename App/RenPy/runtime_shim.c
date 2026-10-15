// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

// Linked into each Ren'Py runtime framework (Scripts/build-renpy-runtimes.sh), not the app.
// SDL's event-injection functions are hidden symbols inside libSDL2, callable from code in
// the same image but not exported from a framework; these wrappers export them.
typedef struct SDL_Window SDL_Window;
int SDL_SendKeyboardKey(unsigned char state, int scancode);
int SDL_SendMouseMotion(SDL_Window *window, unsigned int mouseID, int relative, int x, int y);
int SDL_SendMouseButton(SDL_Window *window, unsigned int mouseID, unsigned char state, unsigned char button);

__attribute__((visibility("default"))) int vnhub_sdl_send_key(unsigned char state, int scancode) {
    return SDL_SendKeyboardKey(state, scancode);
}

__attribute__((visibility("default"))) int vnhub_sdl_send_mouse_motion(SDL_Window *window, int x, int y) {
    return SDL_SendMouseMotion(window, 0, 0, x, y);
}

__attribute__((visibility("default"))) int vnhub_sdl_send_mouse_button(SDL_Window *window, unsigned char state, unsigned char button) {
    return SDL_SendMouseButton(window, 0, state, button);
}

// Input diagnostics: logs SDL's joystick and game-controller events (to stderr, which the
// bootstraps send to the game's console log), to tell whether controller input reaches
// SDL at all.
#include <stdint.h>
#include <stdio.h>
typedef int (*SDL_EventFilter)(void *userdata, void *event);
void SDL_AddEventWatch(SDL_EventFilter filter, void *userdata);

static int injecting = 0;
static int native_controller_events = 0;

static int shiori_input_watch(void *userdata, void *event) {
    static int logged = 0;
    uint32_t type = *(uint32_t *)event;
    if (!injecting && (type == 0x650 || type == 0x651 || type == 0x652)) native_controller_events++;
    const uint8_t *bytes = event;
    // SDL_JoyButtonEvent / SDL_ControllerButtonEvent: type, timestamp, which, button, state.
    switch (type) {
    case 0x603: case 0x604: // SDL_JOYBUTTONDOWN / UP
    case 0x651: case 0x652: // SDL_CONTROLLERBUTTONDOWN / UP
        if (logged++ < 80) {
            fprintf(stderr, "Shiori SDL: %s button %d %s\n", type >= 0x650 ? "controller" : "joystick",
                    bytes[12], (type == 0x603 || type == 0x651) ? "down" : "up");
        }
        break;
    case 0x605: case 0x606: case 0x653: case 0x654: // device added / removed
        fprintf(stderr, "Shiori SDL: event 0x%x (device added/removed)\n", type);
        break;
    }
    return 1;
}

__attribute__((visibility("default"))) void vnhub_sdl_watch_input(void) {
    SDL_AddEventWatch(shiori_input_watch, 0);
}

// SDL's own keyboard-focus window (NULL when SDL thinks no window has focus, in which
// case it drops joystick input unless SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS is set).
SDL_Window *SDL_GetKeyboardFocus(void);

__attribute__((visibility("default"))) int vnhub_sdl_has_keyboard_focus(void) {
    return SDL_GetKeyboardFocus() != 0;
}

// Controller input from Shiori. SDL's iOS (MFi) joystick driver produces no events for
// some controllers (a Backbone, at least) even though GameController reports every
// press, so Shiori reads the pad itself while a game runs and posts standard SDL
// game-controller events for the first controller. Ren'Py and the game see them as
// ordinary pad input. Stops as soon as SDL produces controller events of its own.
int SDL_PushEvent(void *event);
int32_t SDL_JoystickGetDeviceInstanceID(int device_index);
uint32_t SDL_GetTicks(void);

typedef struct {
    uint32_t type, timestamp;
    int32_t which;
    uint8_t button, state, padding1, padding2;
} shiori_button_event;

typedef struct {
    uint32_t type, timestamp;
    int32_t which;
    uint8_t axis, padding1, padding2, padding3;
    int16_t value;
    uint16_t padding4;
} shiori_axis_event;

static int shiori_push(void *event) {
    injecting = 1;
    int result = SDL_PushEvent(event);
    injecting = 0;
    return result;
}

__attribute__((visibility("default"))) int vnhub_sdl_controller_button(int button, int down) {
    if (native_controller_events) return 0;
    union { shiori_button_event button; uint8_t bytes[64]; } event = { 0 };
    event.button.type = down ? 0x651 : 0x652; // SDL_CONTROLLERBUTTONDOWN / UP
    event.button.timestamp = SDL_GetTicks();
    event.button.which = SDL_JoystickGetDeviceInstanceID(0);
    event.button.button = (uint8_t)button;
    event.button.state = down ? 1 : 0;
    return shiori_push(&event);
}

__attribute__((visibility("default"))) int vnhub_sdl_controller_axis(int axis, int value) {
    if (native_controller_events) return 0;
    union { shiori_axis_event axis; uint8_t bytes[64]; } event = { 0 };
    event.axis.type = 0x650; // SDL_CONTROLLERAXISMOTION
    event.axis.timestamp = SDL_GetTicks();
    event.axis.which = SDL_JoystickGetDeviceInstanceID(0);
    event.axis.axis = (uint8_t)axis;
    event.axis.value = (int16_t)value;
    return shiori_push(&event);
}
