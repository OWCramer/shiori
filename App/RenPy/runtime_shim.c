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

static int vnhub_input_watch(void *userdata, void *event) {
    static int logged = 0;
    uint32_t type = *(uint32_t *)event;
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
    SDL_AddEventWatch(vnhub_input_watch, 0);
}
