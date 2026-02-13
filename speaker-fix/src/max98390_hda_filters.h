/* SPDX-License-Identifier: GPL-2.0 */
//
// MAX98390 HDA filter configuration header
//

#ifndef __MAX98390_HDA_FILTERS_H
#define __MAX98390_HDA_FILTERS_H

struct max98390_hda_priv;

void max98390_configure_filters(struct max98390_hda_priv *priv);
void max98390_configure_high_pass_filter(struct max98390_hda_priv *priv, int cutoff_freq, bool is_tweeter);

#endif /* __MAX98390_HDA_FILTERS_H */
