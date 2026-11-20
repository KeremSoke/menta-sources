resources = gnome.compile_resources('menta-sources-resources',
  'menta-sources.gresource.xml',
  source_dir: '.',
  c_name: 'menta_sources',
)

configure_file(
  input: 'org.menta.menta-sources.policy.in',
  output: 'org.menta.menta-sources.policy',
  configuration: config_data,
  install: true,
  install_dir: datadir / 'polkit-1' / 'actions',
)

install_data('menta-sources.desktop', install_dir: datadir / 'applications')
install_data('countries.json', 'Mirrors.masterlist', install_dir: pkgdatadir)
install_data('menta-sources.1', 'add-apt-repository.1', install_dir: mandir / 'man1')
install_data('icons/hicolor/48x48/apps/menta-sources.png', install_dir: datadir / 'icons' / 'hicolor' / '48x48' / 'apps')
install_data('icons/hicolor/scalable/apps/menta-sources.svg', install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps')

foreach codename : ['bookworm', 'trixie', 'forky', 'sid']
  install_data('releases' / codename / 'menta-sources.conf', install_dir: pkgdatadir / codename)
endforeach

install_symlink('apt-add-repository', pointing_to: 'add-apt-repository', install_dir: bindir)
install_symlink('software-properties-gtk', pointing_to: 'menta-sources', install_dir: bindir)
install_symlink('apt-add-repository.1', pointing_to: 'add-apt-repository.1', install_dir: mandir / 'man1')
install_symlink('software-properties-gtk.1', pointing_to: 'menta-sources.1', install_dir: mandir / 'man1')
