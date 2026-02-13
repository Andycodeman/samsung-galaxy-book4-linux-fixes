/* SPDX-License-Identifier: GPL-2.0 */
/*
 * MAX98390 HDA audio driver
 */

#ifndef __MAX98390_HDA_H__
#define __MAX98390_HDA_H__

#include <linux/regmap.h>
#include <sound/hda_codec.h>

enum max98390_hda_bus_type {
	MAX98390_HDA_I2C,
};

struct max98390_hda_priv {
	struct device *dev;
	struct regmap *regmap;
	enum max98390_hda_bus_type bus_type;
	int irq;
	int index;
	const char *acpi_subsystem_id;
	int i2c_addr;  /* I2C address for speaker identification */
};

int max98390_hda_probe(struct device *dev, const char *device_name,
		       int id, int irq, struct regmap *regmap,
		       enum max98390_hda_bus_type bus_type, int i2c_addr);
void max98390_hda_remove(struct device *dev);

extern const struct dev_pm_ops max98390_hda_pm_ops;

#endif /* __MAX98390_HDA_H__ */
