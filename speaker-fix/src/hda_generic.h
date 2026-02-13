/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Minimal shim for HDA generic PCM action constants.
 * Extracted from sound/hda/codecs/generic.h in kernel source.
 * Only the enum values needed by the side-codec playback hook.
 */

#ifndef __HDA_GENERIC_SHIM_H__
#define __HDA_GENERIC_SHIM_H__

enum {
	HDA_GEN_PCM_ACT_OPEN,
	HDA_GEN_PCM_ACT_PREPARE,
	HDA_GEN_PCM_ACT_CLEANUP,
	HDA_GEN_PCM_ACT_CLOSE,
};

#endif /* __HDA_GENERIC_SHIM_H__ */
