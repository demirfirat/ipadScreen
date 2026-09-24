#import "TurboDecoder.h"
#import <stdio.h>
#import <setjmp.h>
#import "jpeglib.h"

/// A single buffer in the pool.
///
/// The CGImage points straight at the buffer (no copy), so the buffer can
/// only be reused once the CGImage is released. The release callback
/// clears the `inUse` flag.
typedef struct {
    void *data;
    size_t capacity;
    volatile int32_t inUse;
} IPSBuffer;

/// On error libjpeg calls `exit()` by default. We longjmp out instead so a
/// corrupt frame doesn't take the app down.
typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
} IPSErrorMgr;

static void IPSErrorExit(j_common_ptr cinfo) {
    IPSErrorMgr *err = (IPSErrorMgr *)cinfo->err;
    longjmp(err->jump, 1);
}

static void IPSEmitMessage(j_common_ptr cinfo, int msgLevel) {
    // Swallow warnings; the odd corrupt frame in a stream is normal.
    (void)cinfo; (void)msgLevel;
}

@implementation TurboDecoder {
    IPSBuffer *_pool;
    NSUInteger _poolCount;
    NSLock *_poolLock;
    CGColorSpaceRef _colorSpace;
}

- (id)initWithPoolSize:(NSUInteger)count {
    self = [super init];
    if (self) {
        _poolCount = MAX(count, (NSUInteger)3);
        _pool = (IPSBuffer *)calloc(_poolCount, sizeof(IPSBuffer));
        _poolLock = [[NSLock alloc] init];
        // DeviceRGB is the no-color-matching path. Choosing sRGB brings in
        // ColorSync and a per-frame conversion cost.
        _colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return self;
}

- (void)dealloc {
    for (NSUInteger i = 0; i < _poolCount; i++) {
        if (_pool[i].data) free(_pool[i].data);
    }
    free(_pool);
    [_poolLock release];
    CGColorSpaceRelease(_colorSpace);
    [super dealloc];
}

/// Finds a free buffer that's big enough.
- (IPSBuffer *)acquireBufferOfSize:(size_t)needed {
    [_poolLock lock];
    IPSBuffer *chosen = NULL;
    for (NSUInteger i = 0; i < _poolCount; i++) {
        if (_pool[i].inUse) continue;
        chosen = &_pool[i];
        break;
    }
    if (chosen) {
        chosen->inUse = 1;
        if (chosen->capacity < needed) {
            if (chosen->data) free(chosen->data);
            // valloc: page-aligned memory, the layout CoreGraphics prefers.
            chosen->data = valloc(needed);
            chosen->capacity = chosen->data ? needed : 0;
        }
    }
    [_poolLock unlock];

    if (chosen && !chosen->data) {
        chosen->inUse = 0;
        return NULL;
    }
    return chosen;
}

/// Returns the buffer to the pool once the CGImage is released.
static void IPSReleaseBuffer(void *info, const void *data, size_t size) {
    (void)data; (void)size;
    IPSBuffer *buf = (IPSBuffer *)info;
    buf->inUse = 0;
}

- (CGImageRef)decode:(NSData *)jpeg {
    struct jpeg_decompress_struct cinfo;
    IPSErrorMgr jerr;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = IPSErrorExit;
    jerr.pub.emit_message = IPSEmitMessage;

    if (setjmp(jerr.jump)) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, (const unsigned char *)[jpeg bytes],
                 (unsigned long)[jpeg length]);

    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    // Decode straight into CoreAnimation's native format: BGRX, 32 bits,
    // no alpha. No color conversion and no intermediate copy, which is
    // where most of the speedup comes from.
    cinfo.out_color_space = JCS_EXT_BGRX;

    // For screen mirroring speed beats quality; these two give a clear
    // speedup with no visible difference.
    cinfo.dct_method = JDCT_IFAST;
    cinfo.do_fancy_upsampling = FALSE;

    jpeg_start_decompress(&cinfo);

    size_t width = cinfo.output_width;
    size_t height = cinfo.output_height;
    size_t stride = width * 4;
    size_t needed = stride * height;

    IPSBuffer *buf = [self acquireBufferOfSize:needed];
    if (!buf) {
        // Every buffer is on screen or mid-decode; skip this frame.
        jpeg_abort_decompress(&cinfo);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    uint8_t *base = (uint8_t *)buf->data;
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = base + cinfo.output_scanline * stride;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }

    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);

    CGDataProviderRef provider =
        CGDataProviderCreateWithData(buf, buf->data, needed, IPSReleaseBuffer);
    if (!provider) {
        buf->inUse = 0;
        return NULL;
    }

    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, _colorSpace,
                                     kCGImageAlphaNoneSkipFirst |
                                     kCGBitmapByteOrder32Little,
                                     provider, NULL, false,
                                     kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);

    if (!image) buf->inUse = 0;
    return image;
}

@end
