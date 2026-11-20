project('menta-sources', 'vala', 'c',
  version: '1.0.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.62.0',
)

i18n = import('i18n')
gnome = import('gnome')

prefix = get_option('prefix')
bindir = prefix / get_option('bindir')
datadir = prefix / get_option('datadir')
libexecdir = prefix / get_option('libexecdir')
localedir = prefix / get_option('localedir')
mandir = prefix / get_option('mandir')
pkgdatadir = datadir / meson.project_name()
helper_dir = libexecdir / meson.project_name()
helper_path = helper_dir / 'menta-sources-helper'

add_project_arguments(
  '-DGETTEXT_PACKAGE="menta-sources"',
  '-w',
  language: 'c',
)

glib = dependency('glib-2.0', version: '>= 2.74')
gobject = dependency('gobject-2.0')
gio = dependency('gio-2.0')
gio_unix = dependency('gio-unix-2.0')
gee = dependency('gee-0.8')
json = dependency('json-glib-1.0')
gtk = dependency('gtk+-3.0', version: '>= 3.24')
soup = dependency('libsoup-3.0')
posix = meson.get_compiler('vala').find_library('posix')

config_data = configuration_data()
config_data.set('VERSION', meson.project_version())
config_data.set('GETTEXT_PACKAGE', 'menta-sources')
config_data.set('LOCALEDIR', localedir)
config_data.set('PKGDATADIR', pkgdatadir)
config_data.set('HELPER_PATH', helper_path)

config_vala = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: config_data,
)

subdir('data')
subdir('src')
subdir('po')
subdir('tests')
