#include "pancake.h"

#include <stdio.h>

int main(void) {
    const uint8_t bytes[] = {0xca, 0xfe, 0x00};
    const PancakeFrame frame = {
        .bytes = bytes,
        .len = sizeof(bytes),
        .shape = PANCAKE_FRAME_SHAPE_BYTE,
    };

    printf("shape=%u bytes=%zu\n", frame.shape, frame.len);
    pancake_managed_frame_release(NULL);

    PancakePeer *peer = NULL;
    if (pancake_peer_new(&peer) != PANCAKE_OK) {
        return 1;
    }
    pancake_peer_release(peer);

    return frame.bytes == NULL ? 1 : 0;
}
