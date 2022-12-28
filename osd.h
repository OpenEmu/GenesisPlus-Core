#ifndef _OSD_H_
#define _OSD_H_

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "scrc32.h"

#define MAX_INPUTS 8
#define CHEATS_UPDATE() ROMCheatUpdate()

void osd_input_update(void);
int load_archive(char*, unsigned char*, int, char *);
extern void ROMCheatUpdate(void);

typedef struct
{
    uint8 padtype;
} t_input_config;

typedef struct
{
    uint8 hq_fm;
    uint8 filter;
    uint8 hq_psg;
    uint8 ym2612;
    uint8 ym2413;
    uint8 cd_latency;
#ifdef HAVE_YM3438_CORE
    uint8 ym3438;
#endif
#ifdef HAVE_OPLL_CORE
    uint8 opll;
#endif
    uint8 mono;
    int16 psg_preamp;
    int16 fm_preamp;
    int16 cdda_volume;
    int16 pcm_volume;
    uint16 lp_range;
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
    uint8 add_on;
    uint8 overscan;
    uint8 ntsc;
    uint8 lcd;
    uint8 gg_extra;
    uint8 render;
    uint8 enhanced_vscroll;
    uint8 enhanced_vscroll_limit;
    t_input_config input[MAX_INPUTS];
} t_config;

extern t_config config;

extern char GG_ROM[256];
extern char AR_ROM[256];
extern char SK_ROM[256];
extern char SK_UPMEM[256];
extern char GG_BIOS[256];
extern char MD_BIOS[256];
extern char CD_BIOS_EU[256];
extern char CD_BIOS_US[256];
extern char CD_BIOS_JP[256];
extern char MS_BIOS_US[256];
extern char MS_BIOS_EU[256];
extern char MS_BIOS_JP[256];

#endif /* _OSD_H_ */
