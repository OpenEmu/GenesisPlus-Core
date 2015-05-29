/*
 Copyright (c) 2015, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#import "GenPlusGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OEGenesisSystemResponderClient.h"
#import "OESegaCDSystemResponderClient.h"
#import <OpenGL/gl.h>

#include "shared.h"
#include "scrc32.h"

static const double pal_fps = 53203424.0 / (3420.0 * 313.0);
static const double ntsc_fps = 53693175.0 / (3420.0 * 262.0);

char GG_ROM[256];
char AR_ROM[256];
char SK_ROM[256];
char SK_UPMEM[256];
char GG_BIOS[256];
char MS_BIOS_EU[256];
char MS_BIOS_JP[256];
char MS_BIOS_US[256];
char CD_BIOS_EU[256];
char CD_BIOS_US[256];
char CD_BIOS_JP[256];
char CD_BRAM_JP[256];
char CD_BRAM_US[256];
char CD_BRAM_EU[256];
char CART_BRAM[256];

// Mega CD backup RAM stuff
static uint32_t brm_crc[2];
static uint8_t brm_format[0x40] =
{
    0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x5f,0x00,0x00,0x00,0x00,0x40,
    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    0x53,0x45,0x47,0x41,0x5f,0x43,0x44,0x5f,0x52,0x4f,0x4d,0x00,0x01,0x00,0x00,0x00,
    0x52,0x41,0x4d,0x5f,0x43,0x41,0x52,0x54,0x52,0x49,0x44,0x47,0x45,0x5f,0x5f,0x5f
};

// Cheat Support
#define MAX_CHEATS (150)
#define MAX_DESC_LENGTH (63)

typedef struct
{
    char code[12];
    char text[MAX_DESC_LENGTH];
    uint8_t enable;
    uint16_t data;
    uint16_t old;
    uint32_t address;
    uint8_t *prev;
} CHEATENTRY;

static int maxcheats = 0;
static int maxROMcheats = 0;
static int maxRAMcheats = 0;
static CHEATENTRY cheatlist[MAX_CHEATS];
static uint8_t cheatIndexes[MAX_CHEATS];
static char ggvalidchars[] = "ABCDEFGHJKLMNPRSTVWXYZ0123456789";
static char arvalidchars[] = "0123456789ABCDEF";

@interface GenPlusGameCore () <OEGenesisSystemResponderClient, OESegaCDSystemResponderClient>
{
    uint32_t *videoBuffer;
    int16_t *soundBuffer;
    NSMutableDictionary *cheatList;
    NSURL *_romFile;
}
- (void)applyCheat:(NSString *)code;
- (void)resetCheats;
- (void)configureOptions;
@end

@implementation GenPlusGameCore

static __weak GenPlusGameCore *_current;

- (id)init
{
    if((self = [super init]))
    {
        videoBuffer = (uint32_t*)malloc(720 * 576 * 4);
        soundBuffer = (int16_t *)malloc(2048 * 2 * 2);
        cheatList = [[NSMutableDictionary alloc] init];
    }

	_current = self;

	return self;
}

- (void)dealloc
{
    free(videoBuffer);
    free(soundBuffer);
}

# pragma mark - Execution

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    _romFile = [NSURL fileURLWithPath:path];

    // Set CD BIOS and BRAM/RAM Cart paths
    snprintf(CD_BIOS_EU, sizeof(CD_BIOS_EU), "%s%sbios_CD_E.bin", [[self biosDirectoryPath] UTF8String], "/");
    snprintf(CD_BIOS_US, sizeof(CD_BIOS_US), "%s%sbios_CD_U.bin", [[self biosDirectoryPath] UTF8String], "/");
    snprintf(CD_BIOS_JP, sizeof(CD_BIOS_JP), "%s%sbios_CD_J.bin", [[self biosDirectoryPath] UTF8String], "/");
    snprintf(CD_BRAM_EU, sizeof(CD_BRAM_EU), "%s%sscd_E.brm", [[self batterySavesDirectoryPath] UTF8String], "/");
    snprintf(CD_BRAM_US, sizeof(CD_BRAM_US), "%s%sscd_U.brm", [[self batterySavesDirectoryPath] UTF8String], "/");
    snprintf(CD_BRAM_JP, sizeof(CD_BRAM_JP), "%s%sscd_J.brm", [[self batterySavesDirectoryPath] UTF8String], "/");
    snprintf(CART_BRAM,  sizeof(CART_BRAM),  "%s%scart.brm",  [[self batterySavesDirectoryPath] UTF8String], "/");

    [self configureOptions];

    if (!load_rom((char *)[path UTF8String]))
        return NO;

    audio_init(48000, vdp_pal ? pal_fps : ntsc_fps);

    system_init();
    system_reset();

    if (system_hw == SYSTEM_MCD)
        bram_load();

    // Set battery saves dir and load sram
    NSString *extensionlessFilename = [[_romFile lastPathComponent] stringByDeletingPathExtension];
    NSURL *batterySavesDirectory = [NSURL fileURLWithPath:[self batterySavesDirectoryPath]];
    [[NSFileManager defaultManager] createDirectoryAtURL:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

    if ([saveFile checkResourceIsReachableAndReturnError:nil])
    {
        NSData *saveData = [NSData dataWithContentsOfURL:saveFile];
        memcpy(sram.sram, [saveData bytes], 0x10000);
        sram.crc = crc32(0, sram.sram, 0x10000);
        NSLog(@"GenesisPlusGX: Loaded sram");
    }

    // Set initial viewport size because the system briefly outputs 256x192 when it boots
    bitmap.viewport.w = 320;
    bitmap.viewport.h = 224;

    return YES;
}

- (void)executeFrame
{
    [self executeFrameSkippingFrame:NO];
}

- (void)executeFrameSkippingFrame:(BOOL)skip
{
    if (system_hw == SYSTEM_MCD)
        system_frame_scd(0);
    else if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        system_frame_gen(0);
    else
        system_frame_sms(0);

    int samples = audio_update(soundBuffer);
    [[self ringBufferAtIndex:0] write:soundBuffer maxLength:samples << 2];
}

- (void)resetEmulation
{
    system_reset();
}

- (void)stopEmulation
{
    if (sram.on)
    {
        // max. supported SRAM size
        unsigned long filesize = 0x10000;

        // only save modified SRAM size
        do
        {
            if (sram.sram[filesize-1] != 0xff)
                break;
        }
        while (--filesize > 0);

        // only save if SRAM has been modified
        if ((filesize != 0) || (crc32(0, &sram.sram[0], 0x10000) != sram.crc))
        {
            NSError *error = nil;
            NSString *extensionlessFilename = [[_romFile lastPathComponent] stringByDeletingPathExtension];
            NSURL *batterySavesDirectory = [NSURL fileURLWithPath:[self batterySavesDirectoryPath]];
            NSURL *saveFile = [batterySavesDirectory URLByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

            // copy SRAM data
            NSData *saveData = [NSData dataWithBytes:sram.sram length:filesize];
            [saveData writeToURL:saveFile options:NSDataWritingAtomic error:&error];

            // update CRC
            sram.crc = crc32(0, sram.sram, 0x10000);

            if (error)
                NSLog(@"GenesisPlusGX: Error writing sram file: %@", error);
            else
                NSLog(@"GenesisPlusGX: Saved sram file: %@", saveFile);
        }
    }

    if (system_hw == SYSTEM_MCD)
        bram_save();

    audio_shutdown();

    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return vdp_pal ? pal_fps : ntsc_fps;
}

# pragma mark - Video

- (const void *)videoBuffer
{
    return videoBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(bitmap.viewport.x, bitmap.viewport.y, bitmap.viewport.w, bitmap.viewport.h);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(bitmap.width, bitmap.height);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

# pragma mark - Audio

- (double)audioSampleRate
{
    return 48000;
}

- (NSUInteger)channelCount
{
    return 2;
}

# pragma mark - Save States

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    int serial_size = STATE_SIZE;
    NSMutableData *stateData = [NSMutableData dataWithLength:serial_size];

    if(!state_save([stateData mutableBytes]))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state data could not be written",
            NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
        }];
        block(NO, error);
        return;
    }

    __autoreleasing NSError *error = nil;
    BOOL success = [stateData writeToFile:fileName options:NSDataWritingAtomic error:&error];

    block(success, success ? nil : error);
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
    __autoreleasing NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:fileName options:NSDataReadingMappedIfSafe | NSDataReadingUncached error:&error];

    if(data == nil)
    {
        block(NO, error);
        return;
    }

    int serial_size = STATE_SIZE;
    if(serial_size != [data length])
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreStateHasWrongSizeError userInfo:@{
            NSLocalizedDescriptionKey : @"Save state has wrong file size.",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the file %@ does not have the right size, %d expected, got: %ld.", fileName, serial_size, [data length]],
        }];
        block(NO, error);
        return;
    }

    if(!state_load((uint8_t *)[data bytes]))
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{
            NSLocalizedDescriptionKey : @"The save state data could not be read",
            NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"Could not read the file state in %@.", fileName]
        }];
        block(NO, error);
        return;
    }

    block(YES, nil);
}

- (NSData *)serializeStateWithError:(NSError **)outError
{
    size_t length = STATE_SIZE;
    void *bytes = malloc(length);
    if(state_save(bytes))
    {
        return [NSData dataWithBytesNoCopy:bytes length:length];
    }
    else
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotSaveStateError
                                         userInfo:@{
                                                    NSLocalizedDescriptionKey : @"Save state data could not be written",
                                                    NSLocalizedRecoverySuggestionErrorKey : @"The emulator could not write the state data."
                                                    }];
        if(outError)
        {
            *outError = error;
        }
        return nil;
    }
}

- (BOOL)deserializeState:(NSData *)state withError:(NSError **)outError
{
    const void *bytes = [state bytes];
    size_t length = [state length];
    size_t serialSize = STATE_SIZE;

    if(serialSize != length)
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreStateHasWrongSizeError
                                         userInfo:@{
                                                    NSLocalizedDescriptionKey : @"Save state has wrong file size.",
                                                    NSLocalizedRecoverySuggestionErrorKey : [NSString stringWithFormat:@"The size of the save state does not have the right size, %lu expected, got: %ld.", serialSize, [state length]],
                                                    }];
        if(outError)
        {
            *outError = error;
        }
        return NO;
    }

    if(state_load((uint8_t *)bytes))
    {
        return YES;
    }
    else
    {
        NSError *error = [NSError errorWithDomain:OEGameCoreErrorDomain
                                             code:OEGameCoreCouldNotLoadStateError
                                         userInfo:@{
                                                    NSLocalizedDescriptionKey : @"The save state data could not be read",
                                                    NSLocalizedRecoverySuggestionErrorKey : @"Could not load data from the save state"
                                                    }];
        if(outError)
        {
            *outError = error;
        }
        return NO;
    }
}

# pragma mark - Input

const int GenesisMap[] = {INPUT_UP, INPUT_DOWN, INPUT_LEFT, INPUT_RIGHT, INPUT_A, INPUT_B, INPUT_C, INPUT_X, INPUT_Y, INPUT_Z, INPUT_START, INPUT_MODE};

- (oneway void)didPushGenesisButton:(OEGenesisButton)button forPlayer:(NSUInteger)player;
{
    input.pad[player-1] |= GenesisMap[button];
}

- (oneway void)didReleaseGenesisButton:(OEGenesisButton)button forPlayer:(NSUInteger)player;
{
    input.pad[player-1] &= ~GenesisMap[button];
}

- (oneway void)didPushSegaCDButton:(OESegaCDButton)button forPlayer:(NSUInteger)player;
{
    input.pad[player-1] |= GenesisMap[button];
}

- (oneway void)didReleaseSegaCDButton:(OESegaCDButton)button forPlayer:(NSUInteger)player;
{
    input.pad[player-1] &= ~GenesisMap[button];
}

#pragma mark - Cheats

- (void)setCheat:(NSString *)code setType:(NSString *)type setEnabled:(BOOL)enabled
{
    // Sanitize
    code = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // Genesis Plus GX expects cheats UPPERCASE
    code = [code uppercaseString];

    // Remove any spaces
    code = [code stringByReplacingOccurrencesOfString:@" " withString:@""];

    if (enabled)
        [cheatList setValue:@YES forKey:code];
    else
        [cheatList removeObjectForKey:code];

    [self resetCheats];

    NSArray *multipleCodes = [[NSArray alloc] init];

    // Apply enabled cheats found in dictionary
    for (id key in cheatList)
    {
        if ([[cheatList valueForKey:key] isEqual:@YES])
        {
            // Handle multi-line cheats
            multipleCodes = [key componentsSeparatedByString:@"+"];

            for (NSString *singleCode in multipleCodes) {
                [self applyCheat:singleCode];
            }
        }
    }
}

# pragma mark - Misc Helper Methods

- (void)applyCheat:(NSString *)code
{
    /* clear existing ROM patches */
    clear_cheats();

    /* interpret code and give it an index */
    decode_cheat((char *)[code UTF8String], maxcheats);

    /* increment cheat count */
    maxcheats++;

    /* apply ROM patches */
    apply_cheats();
}

- (void)resetCheats
{
    /* clear existing ROM patches */
    clear_cheats();

    /* remove cheats from the list */
    remove_cheats();
}

- (void)configureOptions
{
    /* sound options */
    config.psg_preamp     = 150;
    config.fm_preamp      = 100;
    config.hq_fm          = 1; /* high-quality resampling */
    config.psgBoostNoise  = 1;
    config.filter         = 0; /* no filter */
    config.lp_range       = 0x9999; /* 0.6 in 16.16 fixed point */
    config.low_freq       = 880;
    config.high_freq      = 5000;
    config.lg             = 1.0;
    config.mg             = 1.0;
    config.hg             = 1.0;
    config.dac_bits       = 14; /* MAX DEPTH */
    config.ym2413         = 2; /* AUTO */
    config.mono           = 0; /* STEREO output */

    /* system options */
    config.system         = 0; /* AUTO */
    config.region_detect  = 0; /* AUTO */
    config.vdp_mode       = 0; /* AUTO */
    config.master_clock   = 0; /* AUTO */
    config.force_dtack    = 0;
    config.addr_error     = 1;
    config.bios           = 0;
    config.lock_on        = 0;

    /* video options */
    config.overscan = 0; /* 3 == FULL */
    config.gg_extra = 0; /* 1 = show extended Game Gear screen (256x192) */
    config.ntsc     = 0;
    config.render   = 0;

    /* controllers options */
    input.system[0]       = SYSTEM_GAMEPAD;
    input.system[1]       = SYSTEM_GAMEPAD;
    for (unsigned i = 0; i < MAX_INPUTS; i++)
    {
        config.input[i].padtype = DEVICE_PAD6B;
    }

    /* initialize bitmap */
    memset(&bitmap, 0, sizeof(bitmap));
    bitmap.width      = 720;
    bitmap.height     = 576;
    bitmap.pitch      = bitmap.width * sizeof(uint32_t);
    bitmap.data       = (uint8_t *)videoBuffer;
}

/************************************
 * Genesis Plus implementation
 ************************************/
#define CHUNKSIZE   (0x10000)

int load_archive(char *filename, unsigned char *buffer, int maxsize, char *extension)
{
    int size, left;

    /* Open file */
    FILE *fd = fopen(filename, "rb");

    if (!fd)
    {
        /* Master System & Game Gear BIOS are optional files */
        if (!strcmp(filename,MS_BIOS_US) || !strcmp(filename,MS_BIOS_EU) || !strcmp(filename,MS_BIOS_JP) || !strcmp(filename,GG_BIOS))
        {
            return 0;
        }

        /* Mega CD BIOS are required files */
        if (!strcmp(filename,CD_BIOS_US) || !strcmp(filename,CD_BIOS_EU) || !strcmp(filename,CD_BIOS_JP))
        {
            fprintf(stderr, "ERROR - Unable to open CD BIOS: %s.\n", filename);
            return 0;
        }

        fprintf(stderr, "ERROR - Unable to open file.\n");
        return 0;
    }

    /* Get file size */
    fseek(fd, 0, SEEK_END);
    size = ftell(fd);

    /* size limit */
    if(size > maxsize)
    {
        fclose(fd);
        fprintf(stderr, "ERROR - File is too large.\n");
        return 0;
    }

    fprintf(stderr, "INFORMATION - Loading %d bytes ...\n", size);

    /* filename extension */
    if (extension)
    {
        memcpy(extension, &filename[strlen(filename) - 3], 3);
        extension[3] = 0;
    }

    /* Read into buffer */
    left = size;
    fseek(fd, 0, SEEK_SET);
    while (left > CHUNKSIZE)
    {
        fread(buffer, CHUNKSIZE, 1, fd);
        buffer += CHUNKSIZE;
        left -= CHUNKSIZE;
    }

    /* Read remaining bytes */
    fread(buffer, left, 1, fd);

    /* Close file */
    fclose(fd);

    /* Return loaded ROM size */
    return size;
}

void osd_input_update(void)
{
    /* Update RAM patches */
    RAMCheatUpdate();
}

/* Mega CD backup RAM specific */
static void bram_load(void)
{
    FILE *fp;

    /* automatically load internal backup RAM */
    switch (region_code)
    {
        case REGION_JAPAN_NTSC:
            fp = fopen(CD_BRAM_JP, "rb");
            break;
        case REGION_EUROPE:
            fp = fopen(CD_BRAM_EU, "rb");
            break;
        case REGION_USA:
            fp = fopen(CD_BRAM_US, "rb");
            break;
        default:
            return;
    }

    if (fp != NULL)
    {
        fread(scd.bram, 0x2000, 1, fp);
        fclose(fp);

        /* update CRC */
        brm_crc[0] = crc32(0, scd.bram, 0x2000);
    }
    else
    {
        /* force internal backup RAM format (does not use previous region backup RAM) */
        scd.bram[0x1fff] = 0;
    }

    /* check if internal backup RAM is correctly formatted */
    if (memcmp(scd.bram + 0x2000 - 0x20, brm_format + 0x20, 0x20))
    {
        /* clear internal backup RAM */
        memset(scd.bram, 0x00, 0x2000 - 0x40);

        /* internal Backup RAM size fields */
        brm_format[0x10] = brm_format[0x12] = brm_format[0x14] = brm_format[0x16] = 0x00;
        brm_format[0x11] = brm_format[0x13] = brm_format[0x15] = brm_format[0x17] = (sizeof(scd.bram) / 64) - 3;

        /* format internal backup RAM */
        memcpy(scd.bram + 0x2000 - 0x40, brm_format, 0x40);

        /* clear CRC to force file saving (in case previous region backup RAM was also formatted) */
        brm_crc[0] = 0;
    }

    /* automatically load cartridge backup RAM (if enabled) */
    if (scd.cartridge.id)
    {
        fp = fopen(CART_BRAM, "rb");
        if (fp != NULL)
        {
            int filesize = scd.cartridge.mask + 1;
            int done = 0;

            /* Read into buffer (2k blocks) */
            while (filesize > CHUNKSIZE)
            {
                fread(scd.cartridge.area + done, CHUNKSIZE, 1, fp);
                done += CHUNKSIZE;
                filesize -= CHUNKSIZE;
            }

            /* Read remaining bytes */
            if (filesize)
            {
                fread(scd.cartridge.area + done, filesize, 1, fp);
            }

            /* close file */
            fclose(fp);

            /* update CRC */
            brm_crc[1] = crc32(0, scd.cartridge.area, scd.cartridge.mask + 1);
        }

        /* check if cartridge backup RAM is correctly formatted */
        if (memcmp(scd.cartridge.area + scd.cartridge.mask + 1 - 0x20, brm_format + 0x20, 0x20))
        {
            /* clear cartridge backup RAM */
            memset(scd.cartridge.area, 0x00, scd.cartridge.mask + 1);

            /* Cartridge Backup RAM size fields */
            brm_format[0x10] = brm_format[0x12] = brm_format[0x14] = brm_format[0x16] = (((scd.cartridge.mask + 1) / 64) - 3) >> 8;
            brm_format[0x11] = brm_format[0x13] = brm_format[0x15] = brm_format[0x17] = (((scd.cartridge.mask + 1) / 64) - 3) & 0xff;

            /* format cartridge backup RAM */
            memcpy(scd.cartridge.area + scd.cartridge.mask + 1 - 0x40, brm_format, 0x40);
        }
    }
}

static void bram_save(void)
{
    FILE *fp;

    /* verify that internal backup RAM has been modified */
    if (crc32(0, scd.bram, 0x2000) != brm_crc[0])
    {
        /* check if it is correctly formatted before saving */
        if (!memcmp(scd.bram + 0x2000 - 0x20, brm_format + 0x20, 0x20))
        {
            switch (region_code)
            {
                case REGION_JAPAN_NTSC:
                    fp = fopen(CD_BRAM_JP, "wb");
                    break;
                case REGION_EUROPE:
                    fp = fopen(CD_BRAM_EU, "wb");
                    break;
                case REGION_USA:
                    fp = fopen(CD_BRAM_US, "wb");
                    break;
                default:
                    return;
            }

            if (fp != NULL)
            {
                fwrite(scd.bram, 0x2000, 1, fp);
                fclose(fp);

                /* update CRC */
                brm_crc[0] = crc32(0, scd.bram, 0x2000);
            }
        }
    }

    /* verify that cartridge backup RAM has been modified */
    if (scd.cartridge.id && (crc32(0, scd.cartridge.area, scd.cartridge.mask + 1) != brm_crc[1]))
    {
        /* check if it is correctly formatted before saving */
        if (!memcmp(scd.cartridge.area + scd.cartridge.mask + 1 - 0x20, brm_format + 0x20, 0x20))
        {
            fp = fopen(CART_BRAM, "wb");
            if (fp != NULL)
            {
                int filesize = scd.cartridge.mask + 1;
                int done = 0;

                /* Write to file (2k blocks) */
                while (filesize > CHUNKSIZE)
                {
                    fwrite(scd.cartridge.area + done, CHUNKSIZE, 1, fp);
                    done += CHUNKSIZE;
                    filesize -= CHUNKSIZE;
                }

                /* Write remaining bytes */
                if (filesize)
                {
                    fwrite(scd.cartridge.area + done, filesize, 1, fp);
                }

                /* Close file */
                fclose(fp);

                /* update CRC */
                brm_crc[1] = crc32(0, scd.cartridge.area, scd.cartridge.mask + 1);
            }
        }
    }
}

/* Cheat Support */
static uint32_t decode_cheat(char *string, int index)
{
    char *p;
    int i,n;
    uint32_t len = 0;
    uint32_t address = 0;
    uint16_t data = 0;
    uint8_t ref = 0;

    /* 16-bit Game Genie code (ABCD-EFGH) */
    if ((strlen(string) >= 9) && (string[4] == '-'))
    {
        /* 16-bit system only */
        if ((system_hw & SYSTEM_PBC) != SYSTEM_MD)
        {
            return 0;
        }

        for (i = 0; i < 8; i++)
        {
            if (i == 4) string++;
            p = strchr (ggvalidchars, *string++);
            if (p == NULL) return 0;
            n = p - ggvalidchars;

            switch (i)
            {
                case 0:
                    data |= n << 3;
                    break;

                case 1:
                    data |= n >> 2;
                    address |= (n & 3) << 14;
                    break;

                case 2:
                    address |= n << 9;
                    break;

                case 3:
                    address |= (n & 0xF) << 20 | (n >> 4) << 8;
                    break;

                case 4:
                    data |= (n & 1) << 12;
                    address |= (n >> 1) << 16;
                    break;

                case 5:
                    data |= (n & 1) << 15 | (n >> 1) << 8;
                    break;

                case 6:
                    data |= (n >> 3) << 13;
                    address |= (n & 7) << 5;
                    break;

                case 7:
                    address |= n;
                    break;
            }
        }

        /* code length */
        len = 9;
    }

    /* 8-bit Game Genie code (DDA-AAA-XXX) */
    else if ((strlen(string) >= 11) && (string[3] == '-') && (string[7] == '-'))
    {
        /* 8-bit system only */
        if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        {
            return 0;
        }

        /* decode 8-bit data */
        for (i=0; i<2; i++)
        {
            p = strchr (arvalidchars, *string++);
            if (p == NULL) return 0;
            n = (p - arvalidchars) & 0xF;
            data |= (n  << ((1 - i) * 4));
        }

        /* decode 16-bit address (low 12-bits) */
        for (i=0; i<3; i++)
        {
            if (i==1) string++; /* skip separator */
            p = strchr (arvalidchars, *string++);
            if (p == NULL) return 0;
            n = (p - arvalidchars) & 0xF;
            address |= (n  << ((2 - i) * 4));
        }

        /* decode 16-bit address (high 4-bits) */
        p = strchr (arvalidchars, *string++);
        if (p == NULL) return 0;
        n = (p - arvalidchars) & 0xF;
        n ^= 0xF; /* bits inversion */
        address |= (n  << 12);

        /* RAM address are also supported */
        if (address >= 0xC000)
        {
            /* convert to 24-bit Work RAM address */
            address = 0xFF0000 | (address & 0x1FFF);
        }

        /* decode reference 8-bit data */
        for (i=0; i<2; i++)
        {
            string++; /* skip separator and 2nd digit */
            p = strchr (arvalidchars, *string++);
            if (p == NULL) return 0;
            n = (p - arvalidchars) & 0xF;
            ref |= (n  << ((1 - i) * 4));
        }
        ref = (ref >> 2) | ((ref & 0x03) << 6);  /* 2-bit right rotation */
        ref ^= 0xBA;  /* XOR */

        /* update old data value */
        cheatlist[index].old = ref;

        /* code length */
        len = 11;
    }

    /* Action Replay code */
    else if (string[6] == ':')
    {
        if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
        {
            /* 16-bit code (AAAAAA:DDDD) */
            if (strlen(string) < 11) return 0;

            /* decode 24-bit address */
            for (i=0; i<6; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (p == NULL) return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((5 - i) * 4));
            }

            /* decode 16-bit data */
            string++;
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (p == NULL) return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n << ((3 - i) * 4));
            }

            /* code length */
            len = 11;
        }
        else
        {
            /* 8-bit code (xxAAAA:DD) */
            if (strlen(string) < 9) return 0;

            /* decode 16-bit address */
            string+=2;
            for (i=0; i<4; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (p == NULL) return 0;
                n = (p - arvalidchars) & 0xF;
                address |= (n << ((3 - i) * 4));
            }

            /* ROM addresses are not supported */
            if (address < 0xC000) return 0;

            /* convert to 24-bit Work RAM address */
            address = 0xFF0000 | (address & 0x1FFF);

            /* decode 8-bit data */
            string++;
            for (i=0; i<2; i++)
            {
                p = strchr (arvalidchars, *string++);
                if (p == NULL) return 0;
                n = (p - arvalidchars) & 0xF;
                data |= (n  << ((1 - i) * 4));
            }

            /* code length */
            len = 9;
        }
    }

    /* Valid code found ? */
    if (len)
    {
        /* update cheat address & data values */
        cheatlist[index].address = address;
        cheatlist[index].data = data;
        cheatlist[index].enable = 1; // Enable the cheat by default
    }

    /* return code length (0 = invalid) */
    return len;
}

static void apply_cheats(void)
{
    uint8_t *ptr;

    /* clear ROM&RAM patches counter */
    maxROMcheats = maxRAMcheats = 0;

    int i;
    for (i = 0; i < maxcheats; i++)
    {
        if (cheatlist[i].enable)
        {
            if (cheatlist[i].address < cart.romsize)
            {
                if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
                {
                    /* patch ROM data */
                    cheatlist[i].old = *(uint16_t *)(cart.rom + (cheatlist[i].address & 0xFFFFFE));
                    *(uint16_t *)(cart.rom + (cheatlist[i].address & 0xFFFFFE)) = cheatlist[i].data;
                }
                else
                {
                    /* add ROM patch */
                    maxROMcheats++;
                    cheatIndexes[MAX_CHEATS - maxROMcheats] = i;

                    /* get current banked ROM address */
                    ptr = &z80_readmap[(cheatlist[i].address) >> 10][cheatlist[i].address & 0x03FF];

                    /* check if reference matches original ROM data */
                    if (((uint8_t)cheatlist[i].old) == *ptr)
                    {
                        /* patch data */
                        *ptr = cheatlist[i].data;

                        /* save patched ROM address */
                        cheatlist[i].prev = ptr;
                    }
                    else
                    {
                        /* no patched ROM address yet */
                        cheatlist[i].prev = NULL;
                    }
                }
            }
            else if (cheatlist[i].address >= 0xFF0000)
            {
                /* add RAM patch */
                cheatIndexes[maxRAMcheats++] = i;
            }
        }
    }
}

static void clear_cheats(void)
{
    int i = maxcheats;

    /* disable cheats in reversed order in case the same address is used by multiple patches */
    while (i > 0)
    {
        if (cheatlist[i-1].enable)
        {
            if (cheatlist[i-1].address < cart.romsize)
            {
                if ((system_hw & SYSTEM_PBC) == SYSTEM_MD)
                {
                    /* restore original ROM data */
                    *(uint16_t *)(cart.rom + (cheatlist[i-1].address & 0xFFFFFE)) = cheatlist[i-1].old;
                }
                else
                {
                    /* check if previous banked ROM address has been patched */
                    if (cheatlist[i-1].prev != NULL)
                    {
                        /* restore original data */
                        *cheatlist[i-1].prev = cheatlist[i-1].old;

                        /* no more patched ROM address */
                        cheatlist[i-1].prev = NULL;
                    }
                }
            }
        }

        i--;
    }
}

static void remove_cheats(void)
{
    int i = maxcheats;
    while (i > 0)
    {
        if (cheatlist[i-1].enable)
        {
            cheatlist[i-1].text[0] = 0;
            cheatlist[i-1].code[0] = 0;
            cheatlist[i-1].address = 0;
            cheatlist[i-1].data = 0;
            cheatlist[i-1].enable = 0;

            maxcheats--;
        }

        i--;
    }
}

/****************************************************************************
 * RAMCheatUpdate
 *
 * Apply RAM patches (this should be called once per frame)
 *
 ****************************************************************************/
void RAMCheatUpdate(void)
{
    int index, cnt = maxRAMcheats;

    while (cnt)
    {
        /* get cheat index */
        index = cheatIndexes[--cnt];

        /* apply RAM patch */
        //if (cheatlist[index].data & 0xFF00)
        if (cheatlist[index].data & 0x00FF) // For LSB?
        {
            /* word patch */
            *(uint16_t *)(work_ram + (cheatlist[index].address & 0xFFFE)) = cheatlist[index].data;
        }
        else
        {
            /* byte patch */
            work_ram[cheatlist[index].address & 0xFFFF] = cheatlist[index].data;
        }
    }
}

@end
