/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * HD audio Component Binding Interface
 * From sound/hda/codecs/side-codecs/hda_component.h in kernel v6.17.
 *
 * Copyright (C) 2021 Cirrus Logic, Inc. and
 *                    Cirrus Logic International Semiconductor Ltd.
 */

#ifndef __HDA_SCODEC_COMPONENT_H__
#define __HDA_SCODEC_COMPONENT_H__

#include <linux/acpi.h>
#include <linux/component.h>
#include <linux/mutex.h>
#include <sound/hda_codec.h>

#define HDA_MAX_COMPONENTS	4
#define HDA_MAX_NAME_SIZE	50

struct hda_component {
	struct device *dev;
	char name[HDA_MAX_NAME_SIZE];
	struct acpi_device *adev;
	bool acpi_notifications_supported;
	void (*acpi_notify)(acpi_handle handle, u32 event, struct device *dev);
	void (*pre_playback_hook)(struct device *dev, int action);
	void (*playback_hook)(struct device *dev, int action);
	void (*post_playback_hook)(struct device *dev, int action);
};

struct hda_component_parent {
	struct mutex mutex;
	struct hda_codec *codec;
	struct hda_component comps[HDA_MAX_COMPONENTS];
};

static inline struct hda_component *hda_component_from_index(struct hda_component_parent *parent,
							     int index)
{
	if (!parent)
		return NULL;

	if (index < 0 || index >= ARRAY_SIZE(parent->comps))
		return NULL;

	return &parent->comps[index];
}

#endif /* __HDA_SCODEC_COMPONENT_H__ */
