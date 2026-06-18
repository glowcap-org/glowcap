/* Frame ownership over the C ABI: a borrowed PancakeFrame view over caller-owned
   bytes, the same shape as examples/zig/frame_view.zig. */

#include "pancake_ocapn.h"

#include <stdio.h>

int main(void) {
    const uint8_t bytes[] = {0xca, 0xfe, 0x00};
    const PancakeFrame frame = {
        .bytes = bytes,
        .len = sizeof(bytes),
        .shape = PANCAKE_FRAME_SHAPE_BYTE,
    };

    printf("shape=%u bytes=%zu\n", frame.shape, frame.len);
    return 0;
}
