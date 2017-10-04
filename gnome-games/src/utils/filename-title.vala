// This file is part of GNOME Games. License: GPL-3.0+.

public class Games.FilenameTitle : Object, Title {
	private static Regex filename_ext_regex;

	private Uri uri;

	static construct {
		filename_ext_regex = /\.\w+$/;
	}

	public FilenameTitle (Uri uri) {
		this.uri = uri;
	}

	public string get_title () throws Error {
		var file = uri.to_file ();
		var name = file.get_basename ();
		name = filename_ext_regex.replace (name, name.length, 0, "");
		name = name.split ("(")[0];
		name = name.strip ();

		return name;
	}
}
