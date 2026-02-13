KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build

# Two modules: the core library and the I2C transport
obj-m += snd-hda-scodec-max98390.o
obj-m += snd-hda-scodec-max98390-i2c.o

snd-hda-scodec-max98390-y := max98390_hda.o max98390_hda_filters.o
snd-hda-scodec-max98390-i2c-y := max98390_hda_i2c.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

install:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules_install
	depmod -a $(KVER)
