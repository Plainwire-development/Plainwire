// less plugin

module.exports = {
  install(less, pluginManager, functions) {
    const { Color, Dimension } = less.tree;
    const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
    const rgb = (c) => {
      if (c instanceof Color) return c.rgb.slice(0, 3);
      const hex = String(c.value || '#000000').replace('#', '');
      const i = parseInt(hex.padEnd(6, '0'), 16);
      return [(i >> 16) & 255, (i >> 8) & 255, i & 255];
    };
    const color = (a) => new Color([clamp(a[0]), clamp(a[1]), clamp(a[2])]);
    const luma = (c) => {
      const [r, g, b] = rgb(c).map((v) => {
        const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
      });
      return 0.2126 * r + 0.7152 * g + 0.0722 * b;
    };

    const UNIT = 4;
    const RADII = { sm: 8, md: 10, lg: 12, xl: 14, '2xl': 16, '3xl': 18 };

    functions.add('sp', (n) => new Dimension((n.value || 1) * UNIT, 'px'));
    functions.add('r', (k) => {
      const key = String(k.value);
      return RADII[key] ? new Dimension(RADII[key], 'px') : new Dimension(0, 'px');
    });
    functions.add('on', (c) => new Color(luma(c) > 0.4 ? [0x16, 0x22, 0x34] : [255, 255, 255]));
    functions.add('multiply', (a, b) => {
      const x = rgb(a);
      const y = rgb(b);
      return color([(x[0] * y[0]) / 255, (x[1] * y[1]) / 255, (x[2] * y[2]) / 255]);
    });
    functions.add('screen', (a, b) => {
      const x = rgb(a);
      const y = rgb(b);
      return color([
        255 - ((255 - x[0]) * (255 - y[0])) / 255,
        255 - ((255 - x[1]) * (255 - y[1])) / 255,
        255 - ((255 - x[2]) * (255 - y[2])) / 255,
      ]);
    });
  },
};
