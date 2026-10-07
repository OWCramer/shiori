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
