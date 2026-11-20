using Menta;

const string SAMPLE = """Site: cdimage.debian.org
Country: SE Sweden
Type: Origin
CDImage-http: /debian-cd/

Site: deb.debian.org
Type: GeoDNS
Archive-architecture: amd64 arm64 i386
Archive-http: /debian/

Site: ftp.at.debian.org
Country: AT Austria
Archive-architecture: amd64 arm64 i386
Archive-http: /debian/

Site: mirror.example.at
Country: AT Austria
Location: Vienna
Archive-architecture: amd64
Archive-http: /pub/debian/

Site: ports.example.org
Country: DE Germany
Archive-architecture: !s390x
Archive-http: /debian/

Site: old.example.org
Country: NL Netherlands
Old-http: /debian-archive/
""";

void test_parse () {
    var mirrors = Masterlist.parse (SAMPLE, { "amd64" });
    assert_cmpint (mirrors.size, CompareOperator.EQ, 4);
    assert_cmpstr (mirrors[0].url, CompareOperator.EQ, "https://deb.debian.org/debian");
    assert_cmpstr (mirrors[0].country_code, CompareOperator.EQ, WORLDWIDE);
    assert_cmpstr (mirrors[1].url, CompareOperator.EQ, "http://ftp.at.debian.org/debian");
    assert_cmpstr (mirrors[1].country_code, CompareOperator.EQ, "AT");
    assert_cmpstr (mirrors[2].url, CompareOperator.EQ, "http://mirror.example.at/pub/debian");
    assert_cmpstr (mirrors[2].location, CompareOperator.EQ, "Vienna");
    assert_cmpstr (mirrors[3].url, CompareOperator.EQ, "http://ports.example.org/debian");
}

void test_architecture_filter () {
    var mirrors = Masterlist.parse (SAMPLE, { "amd64", "i386" });
    assert_cmpint (mirrors.size, CompareOperator.EQ, 3);
    mirrors = Masterlist.parse (SAMPLE, { "s390x" });
    assert_cmpint (mirrors.size, CompareOperator.EQ, 0);
}

void test_shipped_masterlist () {
    string content;
    try {
        FileUtils.get_contents (Environment.get_variable ("MENTA_MASTERLIST"), out content);
    } catch (FileError e) {
        error ("%s", e.message);
    }
    var mirrors = Masterlist.parse (content, { "amd64" });
    assert_cmpint (mirrors.size, CompareOperator.GT, 100);
    assert_cmpstr (mirrors[0].url, CompareOperator.EQ, "https://deb.debian.org/debian");
    foreach (var mirror in mirrors) {
        assert_true (mirror.url.has_prefix ("http://") || mirror.url.has_prefix ("https://"));
        assert_false (mirror.url.has_suffix ("/"));
    }
}

void test_record_layout () {
    var mirrors = Masterlist.parse ("Site: a.example.org\nCountry: DE Germany\nArchive-http: /debian/\n\nCountry: PL Poland\nSite: b.example.pl\nArchive-http:/debian/\n", { "amd64" });
    assert_cmpint (mirrors.size, CompareOperator.EQ, 2);
    assert_cmpstr (mirrors[0].country_code, CompareOperator.EQ, "DE");
    assert_cmpstr (mirrors[1].country_code, CompareOperator.EQ, "PL");
    assert_cmpstr (mirrors[1].url, CompareOperator.EQ, "http://b.example.pl/debian");
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/masterlist/parse", test_parse);
    Test.add_func ("/masterlist/architecture-filter", test_architecture_filter);
    Test.add_func ("/masterlist/shipped", test_shipped_masterlist);
    Test.add_func ("/masterlist/record-layout", test_record_layout);
    return Test.run ();
}
