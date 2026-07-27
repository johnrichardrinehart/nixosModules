#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <wayland-client.h>

#include "virtual-pointer-client-protocol.h"

struct state {
  struct zwlr_virtual_pointer_manager_v1 *manager;
};

static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
  struct state *state = data;
  if (strcmp(interface, zwlr_virtual_pointer_manager_v1_interface.name) == 0) {
    uint32_t bind_version = version < 2 ? version : 2;
    state->manager = wl_registry_bind(
        registry, name, &zwlr_virtual_pointer_manager_v1_interface, bind_version);
  }
}

static void global_remove(void *data, struct wl_registry *registry,
                          uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = global,
    .global_remove = global_remove,
};

static uint32_t monotonic_msec(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
    return 0;
  }
  return (uint32_t)((uint64_t)now.tv_sec * 1000U + now.tv_nsec / 1000000U);
}

int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (display == NULL) {
    fprintf(stderr, "niri-remote-pointer: cannot connect to Wayland\n");
    return EXIT_FAILURE;
  }

  struct state state = {0};
  struct wl_registry *registry = wl_display_get_registry(display);
  wl_registry_add_listener(registry, &registry_listener, &state);
  if (wl_display_roundtrip(display) < 0 || state.manager == NULL) {
    fprintf(stderr, "niri-remote-pointer: virtual pointer is unavailable\n");
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return EXIT_FAILURE;
  }

  struct zwlr_virtual_pointer_v1 *pointer =
      zwlr_virtual_pointer_manager_v1_create_virtual_pointer(state.manager, NULL);
  char line[256];
  while (fgets(line, sizeof(line), stdin) != NULL) {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
    if (sscanf(line, "A %u %u %u %u", &x, &y, &width, &height) != 4 ||
        width == 0 || height == 0 || x >= width || y >= height) {
      fprintf(stderr, "niri-remote-pointer: rejected malformed motion\n");
      continue;
    }
    zwlr_virtual_pointer_v1_motion_absolute(pointer, monotonic_msec(), x, y,
                                             width, height);
    zwlr_virtual_pointer_v1_frame(pointer);
    if (wl_display_flush(display) < 0 && errno != EAGAIN) {
      break;
    }
  }

  zwlr_virtual_pointer_v1_destroy(pointer);
  zwlr_virtual_pointer_manager_v1_destroy(state.manager);
  wl_registry_destroy(registry);
  wl_display_disconnect(display);
  return EXIT_SUCCESS;
}
