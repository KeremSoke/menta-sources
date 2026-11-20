test_env = environment()
test_env.set('MENTA_TESTDATA', meson.current_source_dir() / 'data')
test_env.set('MENTA_RELEASES', meson.project_source_root() / 'data' / 'releases')
test_env.set('MENTA_MASTERLIST', meson.project_source_root() / 'data' / 'Mirrors.masterlist')

foreach name : ['test-apt-sources', 'test-debian-repos', 'test-mirrors']
  test(name,
    executable(name, name + '.vala', dependencies: [core_dep]),
    env: test_env,
  )
endforeach
