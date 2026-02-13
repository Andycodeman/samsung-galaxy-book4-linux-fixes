/* SPDX-License-Identifier: GPL-2.0 */
/*
 * MAX98390 register definitions and regmap config for HDA side-codec driver.
 * Register defines extracted from upstream sound/soc/codecs/max98390.h.
 * Regmap config defined locally to avoid depending on the ASoC module export.
 */

#ifndef __MAX98390_REGS_H__
#define __MAX98390_REGS_H__

#include <linux/regmap.h>

/* MAX98390 Register Addresses */
#define MAX98390_SOFTWARE_RESET			0x2000
#define MAX98390_CLK_MON			0x2012
#define MAX98390_DAT_MON			0x2014
#define MAX98390_PCM_RX_EN_A			0x201b
#define MAX98390_PCM_CH_SRC_1			0x2021
#define MAX98390_PCM_MODE_CFG			0x2024
#define MAX98390_PCM_MASTER_MODE		0x2025
#define MAX98390_PCM_CLK_SETUP			0x2026
#define MAX98390_PCM_SR_SETUP			0x2027
#define MAX98390_R203A_AMP_EN			0x203a
#define MAX98390_PWR_GATE_CTL			0x2050
#define MAX98390_ENV_TRACK_VOUT_HEADROOM	0x2076
#define MAX98390_BOOST_BYPASS1			0x207c
#define MAX98390_FET_SCALING3			0x2081
#define MAX98390_R23E1_DSP_GLOBAL_EN		0x23e1
#define MAX98390_R23FF_GLOBAL_EN		0x23FF
#define MAX98390_R24FF_REV_ID			0x24FF

/*
 * Local regmap config for the HDA side-codec I2C driver.
 * We use REGCACHE_NONE since we don't have the full reg_defaults table
 * from the ASoC driver. This means every read hits hardware, which is
 * acceptable for an initialization-heavy driver like this.
 */
static const struct regmap_config max98390_regmap = {
	.reg_bits	= 16,
	.val_bits	= 8,
	.max_register	= MAX98390_R24FF_REV_ID,
	.cache_type	= REGCACHE_NONE,
};

#endif /* __MAX98390_REGS_H__ */
