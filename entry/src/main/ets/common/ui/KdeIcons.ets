import { UiTheme } from './UiTheme';

/**
 * Huawei system symbols (sys.symbol resources) — reliable across form factors.
 * Names verified against openharmony id_defined.json.
 */
export class KdeIconRes {
  static menu(): Resource {
    return $r('sys.symbol.line_3_horizontal');
  }

  static arrowBack(): Resource {
    return $r('sys.symbol.chevron_left');
  }

  static chevronRight(): Resource {
    return $r('sys.symbol.chevron_right');
  }

  static check(): Resource {
    return $r('sys.symbol.checkmark');
  }

  static refresh(): Resource {
    return $r('sys.symbol.arrow_clockwise');
  }

  static moreVert(): Resource {
    return $r('sys.symbol.more');
  }

  static settings(): Resource {
    return $r('sys.symbol.gearshape');
  }

  static info(): Resource {
    return $r('sys.symbol.info_circle');
  }

  static addCircle(): Resource {
    return $r('sys.symbol.plus_circle');
  }

  static contentPaste(): Resource {
    return $r('sys.symbol.text_clipboard');
  }

  static errorOutline(): Resource {
    return $r('sys.symbol.exclamationmark_circle');
  }

  static key(): Resource {
    return $r('sys.symbol.key');
  }

  static phonelink(): Resource {
    return $r('sys.symbol.pc_and_phone_fill');
  }

  static phonelinkOff(): Resource {
    return $r('sys.symbol.link_slash');
  }

  static ping(): Resource {
    return $r('sys.symbol.dot_radiowaves_left_and_right');
  }

  static warning(): Resource {
    return $r('sys.symbol.exclamationmark_triangle');
  }

  static app(): Resource {
    return $r('sys.symbol.dual_phone_pairing');
  }

  static phone(): Resource {
    return $r('sys.symbol.phone');
  }

  static computer(): Resource {
    return $r('sys.symbol.computer');
  }

  static desktop(): Resource {
    return $r('sys.symbol.desktop');
  }

  static wifi(): Resource {
    return $r('sys.symbol.wifi');
  }

  static link(): Resource {
    return $r('sys.symbol.link');
  }

  // Plugin & menu action icons
  static shield(): Resource {
    return $r('sys.symbol.key');
  }

  static extension(): Resource {
    return $r('sys.symbol.gearshape');
  }

  static fileUpload(): Resource {
    return $r('sys.symbol.link');
  }

  static music(): Resource {
    return $r('sys.symbol.dot_radiowaves_left_and_right');
  }

  static touchpad(): Resource {
    return $r('sys.symbol.pc_and_phone_fill');
  }

  static terminal(): Resource {
    return $r('sys.symbol.link');
  }

  static slideshow(): Resource {
    return $r('sys.symbol.tv_and_rectangle_portrait');
  }

  static draw(): Resource {
    return $r('sys.symbol.text_clipboard');
  }

  static forDeviceType(deviceType: string): Resource {
    let t = (deviceType ?? '').toLowerCase();
    if (t === 'phone' || t === 'smartphone') {
      return KdeIconRes.phone();
    }
    if (t === 'tablet') {
      return $r('sys.symbol.pad_and_iphone');
    }
    if (t === 'tv') {
      return $r('sys.symbol.tv_and_rectangle_portrait');
    }
    if (t === 'desktop') {
      return KdeIconRes.desktop();
    }
    // laptop / unknown
    return KdeIconRes.computer();
  }
}

/** @deprecated alias — path strings no longer used; kept so old imports don't break types. */
export class KdeIconPaths {
  static readonly ping: string = 'ping';
  static readonly info: string = 'info';
  static readonly laptop: string = 'laptop';
}

/**
 * System SymbolGlyph wrapper (Huawei built-in icons).
 */
@Component
export struct KdeIcon {
  @Prop symbol: Resource = $r('sys.symbol.computer');
  /** Avoid naming `size` — conflicts with CustomComponent.size(). */
  @Prop iconSize: number = UiTheme.iconSize;
  @Prop color: ResourceColor = UiTheme.iconTint;

  build() {
    SymbolGlyph(this.symbol)
      .fontSize(this.iconSize)
      .fontColor([this.color])
      .fontWeight(FontWeight.Normal)
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
  }
}
