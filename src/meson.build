core_sources = files(
  'core/apt-sources.vala',
  'core/debian-repos.vala',
  'core/debversion.vala',
  'core/mirrors.vala',
  'core/storage.vala',
)

core_deps = [glib, gobject, gio, gio_unix, gee, json, posix]

core_lib = static_library('menta-core',
  core_sources, config_vala,
  dependencies: core_deps,
  vala_header: 'menta-core.h',
  vala_vapi: 'menta-core.vapi',
)

core_dep = declare_dependency(
  link_with: core_lib,
  dependencies: core_deps,
  include_directories: include_directories('.'),
)

executable('menta-sources-helper',
  'helper/helper.vala',
  'helper/apt-command.vala',
  dependencies: [core_dep],
  install: true,
  install_dir: helper_dir,
)

executable('add-apt-repository',
  'cli/add-apt-repository.vala',
  dependencies: [core_dep],
  install: true,
)

subdir('app')
