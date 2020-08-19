#ifndef _OSD_H
#define _OSD_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_INPUTS 8

#ifndef TRUE
#define TRUE 1
#endif

#ifndef FALSE
#define FALSE 0
#endif

#ifndef M_PI
#define M_PI 3.1415926535897932385
#endif

#define CHEATS_UPDATE() ROMCheatUpdate()

typedef struct 
{
    int8 device;
    uint8 port;
    uint8 padtype;
} t_input_config;

typedef struct
{
    char version[16];
    uint8 hq_fm;
    uint8 filter;
    uint8 hq_psg;
    uint8 ym2612;
    uint8 ym2413;
#ifdef HAVE_YM3438_CORE
    uint8 ym3438;
#endif
    uint8 mono;
    int16 psg_preamp;
    int16 fm_preamp;
    int16 lp_range;
    int16 low_freq;
    int16 high_freq;
    int16 lg;
    int16 mg;
    int16 hg;
    uint8 system;
    uint8 region_detect;
    uint8 master_clock;
    uint8 vdp_mode;
    uint8 force_dtack;
    uint8 addr_error;
    uint8 bios;
    uint8 lock_on;
    uint8 overscan;
    uint8 gg_extra;
    uint8 ntsc;
    uint8 lcd;
    uint8 render;
    t_input_config input[MAX_INPUTS];
} t_config;

extern char GG_ROM[256];
extern char AR_ROM[256];
extern char SK_ROM[256];
extern char SK_UPMEM[256];
extern char GG_BIOS[256];
extern char CD_BIOS_EU[256];
extern char CD_BIOS_US[256];
extern char CD_BIOS_JP[256];
extern char MS_BIOS_US[256];
extern char MS_BIOS_EU[256];
extern char MS_BIOS_JP[256];

extern t_config config;

void osd_input_update(void);
int load_archive(char *filename, unsigned char *buffer, int maxsize, char *extension);
extern void ROMCheatUpdate(void);

#endif /* _OSD_H */
