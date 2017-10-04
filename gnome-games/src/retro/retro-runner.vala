// This file is part of GNOME Games. License: GPL-3.0+.

public class Games.RetroRunner : Object, Runner {
	public bool can_fullscreen {
		get { return true; }
	}

	public bool can_quit_safely {
		get { return !should_save; }
	}

	public bool can_resume {
		get {
			try {
				init ();
				if (!core.supports_serialization ())
					return false;

				var snapshot_path = get_snapshot_path ();
				var file = File.new_for_path (snapshot_path);

				return file.query_exists ();
			}
			catch (Error e) {
				warning (e.message);
			}

			return false;
		}
	}

	private MediaSet _media_set;
	public MediaSet? media_set {
		get { return _media_set; }
	}

	private Retro.Core core;
	private Retro.CoreView view;
	private RetroInputManager input_manager;
	private Retro.MainLoop loop;

	private string save_directory_path;
	private string save_path;
	private string snapshot_path;
	private string screenshot_path;

	private Retro.CoreDescriptor core_descriptor;
	private RetroCoreSource core_source;
	private Uid uid;
	private InputCapabilities input_capabilities;
	private Settings settings;
	private Title game_title;

	private bool _running;
	private bool running {
		set {
			_running = value;

			if (running)
				should_save = true;

			view.sensitive = running;
		}
		get { return _running; }
	}

	private bool is_initialized;
	private bool is_ready;
	private bool should_save;

	public RetroRunner (RetroCoreSource core_source, Uri uri, Uid uid, Title game_title) {
		is_initialized = false;
		is_ready = false;
		should_save = false;

		this.core_descriptor = null;
		var game_media = new Media ();
		game_media.add_uri (uri);
		_media_set = new MediaSet ();
		_media_set.add_media (game_media);

		this.uid = uid;
		this.core_source = core_source;
		this.input_capabilities = null;
		this.game_title = game_title;
	}

	public RetroRunner.for_media_set_and_input_capabilities (RetroCoreSource core_source, MediaSet media_set, Uid uid, InputCapabilities input_capabilities, Title game_title) {
		is_initialized = false;
		is_ready = false;
		should_save = false;

		this.core_descriptor = null;
		this.core_source = core_source;
		this._media_set = media_set;
		this.uid = uid;
		this.input_capabilities = input_capabilities;
		this.game_title = game_title;

		_media_set.notify["selected-media-number"].connect (on_media_number_changed);
	}

	public RetroRunner.for_core_descriptor (Retro.CoreDescriptor core_descriptor, Uid uid, Title game_title) {
		is_initialized = false;
		is_ready = false;
		should_save = false;

		this.core_descriptor = core_descriptor;
		this.core_source = null;
		this._media_set = new MediaSet ();
		this.uid = uid;
		this.input_capabilities = null;
		this.game_title = game_title;
	}

	construct {
		settings = new Settings ("org.gnome.Games");
	}

	~RetroRunner () {
		pause ();
		deinit ();
	}

	public bool check_is_valid (out string error_message) throws Error {
		try {
			load_media_data ();
			init ();
		}
		catch (RetroError.MODULE_NOT_FOUND e) {
			debug (e.message);
			error_message = get_unsupported_system_message ();

			return false;
		}
		catch (RetroError.FIRMWARE_NOT_FOUND e) {
			debug (e.message);
			error_message = get_unsupported_system_message ();

			return false;
		}

		return true;
	}

	public Gtk.Widget get_display () {
		return view;
	}

	public void start () throws Error {
		load_media_data ();

		if (!is_initialized)
			init();

		loop.stop ();

		if (!is_ready) {
			load_ram ();
			is_ready = true;
		}
		core.reset ();

		loop.start ();
		running = true;
	}

	public void resume () throws Error {
		if (!is_initialized)
			init();

		loop.stop ();

		if (!is_ready) {
			load_ram ();
			core.reset ();
			load_snapshot ();
			is_ready = true;
		}

		loop.start ();
		running = true;
	}

	private void init () throws Error {
		if (is_initialized)
			return;

		view = new Retro.CoreView ();
		settings.changed["video-filter"].connect (on_video_filter_changed);
		on_video_filter_changed ();

		var present_analog_sticks = input_capabilities == null || input_capabilities.get_allow_analog_gamepads ();
		input_manager = new RetroInputManager (view, present_analog_sticks);

		prepare_core ();

		core.shutdown.connect (on_shutdown);

		core.run (); // Needed to finish preparing some cores.

		loop = new Retro.MainLoop (core);
		running = false;

		load_screenshot ();

		is_initialized = true;
	}

	private void deinit () {
		if (!is_initialized)
			return;

		settings.changed["video-filter"].disconnect (on_video_filter_changed);

		core = null;
		view.set_core (null);
		view = null;
		input_manager = null;
		loop = null;

		_running = false;
		is_initialized = false;
		is_ready = false;
		should_save = false;
	}

	private void on_video_filter_changed () {
		var filter_name = settings.get_string ("video-filter");
		var filter = Retro.VideoFilter.from_string (filter_name);
		view.set_filter (filter);
	}

	private void prepare_core () throws Error {
		string module_path;
		if (core_descriptor != null) {
			var module_file = core_descriptor.get_module_file ();
			if (module_file == null)
				throw new RetroError.MODULE_NOT_FOUND (_("No module found for “%s”."), core_descriptor.get_name ());

			module_path = module_file.get_path ();
		}
		else
			module_path = core_source.get_module_path ();
		core = new Retro.Core (module_path);

		if (core_source != null) {
			var platforms_dir = Application.get_platforms_dir ();
			var platform = core_source.get_platform ();
			core.system_directory = @"$platforms_dir/$platform/system";

			var save_directory = get_save_directory_path ();
			try_make_dir (save_directory);
			core.save_directory = save_directory;
		}

		core.log.connect (Retro.g_log);
		view.set_core (core);
		core.input_interface = input_manager;
		core.rumble_interface = input_manager;

		string[] medias_uris = {};
		media_set.foreach_media ((media) => {
			var uris = media.get_uris ();
			medias_uris += (uris.length == 0) ? "" : uris[0].to_string ();
		});

		core.set_medias (medias_uris);

		core.init ();

		core.set_current_media (media_set.selected_media_number);
	}

	public void pause () {
		if (!is_initialized)
			return;

		loop.stop ();
		running = false;


		try {
			save ();
		}
		catch (Error e) {
			warning (e.message);
		}
	}

	public void stop () {
		if (!is_initialized)
			return;

		pause ();
		deinit ();

		stopped ();
	}

	private void on_media_number_changed () {
		if (!is_initialized)
			return;

		try {
			core.set_current_media (media_set.selected_media_number);
		}
		catch (Error e) {
			debug (e.message);

			return;
		}

		var media_number = media_set.selected_media_number;

		Media media = null;
		try {
			media = media_set.get_selected_media (media_number);
		}
		catch (Error e) {
			warning (e.message);

			return;
		}

		var uris = media.get_uris ();
		if (uris.length == 0)
			return;

		try {
			core.set_current_media (media_set.selected_media_number);
		}
		catch (Error e) {
			debug (e.message);

			return;
		}

		try {
			save_media_data ();
		}
		catch (Error e) {
			warning (e.message);
		}
	}

	private void save () throws Error {
		if (!should_save)
			return;

		save_ram ();

		if (media_set.get_size () > 1)
			save_media_data ();

		if (!core.supports_serialization ())
			return;

		save_snapshot ();
		save_screenshot ();

		should_save = false;
	}

	private string get_save_directory_path () throws Error {
		if (save_directory_path != null)
			return save_directory_path;

		var dir = Application.get_saves_dir ();
		var uid = uid.get_uid ();
		save_directory_path = @"$dir/$uid";

		return save_directory_path;
	}

	private string get_save_path () throws Error {
		if (save_path != null)
			return save_path;

		var dir = Application.get_saves_dir ();
		var uid = uid.get_uid ();
		save_path = @"$dir/$uid.save";

		return save_path;
	}

	private void save_ram () throws Error{
		var save = core.get_memory (Retro.MemoryType.SAVE_RAM);
		if (save.length == 0)
			return;

		var dir = Application.get_saves_dir ();
		try_make_dir (dir);

		var save_path = get_save_path ();

		FileUtils.set_data (save_path, save);
	}

	private void load_ram () throws Error {
		var save_path = get_save_path ();

		if (!FileUtils.test (save_path, FileTest.EXISTS))
			return;

		uint8[] data = null;
		FileUtils.get_data (save_path, out data);

		var expected_size = core.get_memory_size (Retro.MemoryType.SAVE_RAM);
		if (data.length != expected_size)
			warning ("Unexpected RAM data size: got %lu, expected %lu\n", data.length, expected_size);

		core.set_memory (Retro.MemoryType.SAVE_RAM, data);
	}

	private string get_snapshot_path () throws Error {
		if (snapshot_path != null)
			return snapshot_path;

		var dir = Application.get_snapshots_dir ();
		var uid = uid.get_uid ();
		snapshot_path = @"$dir/$uid.snapshot";

		return snapshot_path;
	}

	private void save_snapshot () throws Error {
		if (!core.supports_serialization ())
			return;

		var buffer = core.serialize_state ();

		var dir = Application.get_snapshots_dir ();
		try_make_dir (dir);

		var snapshot_path = get_snapshot_path ();

		FileUtils.set_data (snapshot_path, buffer);
	}

	private void load_snapshot () throws Error {
		if (!core.supports_serialization ())
			return;

		var snapshot_path = get_snapshot_path ();

		if (!FileUtils.test (snapshot_path, FileTest.EXISTS))
			return;

		uint8[] data = null;
		FileUtils.get_data (snapshot_path, out data);

		core.deserialize_state (data);
	}

	private void save_media_data () throws Error {
		var dir = Application.get_medias_dir ();
		try_make_dir (dir);

		var medias_path = get_medias_path ();

		string contents = media_set.selected_media_number.to_string();

		FileUtils.set_contents (medias_path, contents, contents.length);
	}

	private void load_media_data () throws Error {
		var medias_path = get_medias_path ();

		if (!FileUtils.test (medias_path, FileTest.EXISTS))
			return;

		string contents;
		FileUtils.get_contents (medias_path, out contents);

		int disc_num = int.parse(contents);
		media_set.selected_media_number = disc_num;
	}

	private string get_medias_path () throws Error {
		var dir = Application.get_medias_dir ();
		var uid = uid.get_uid ();

		return @"$dir/$uid.media";
	}

	private string get_screenshot_path () throws Error {
		if (screenshot_path != null)
			return screenshot_path;

		var dir = Application.get_snapshots_dir ();
		var uid = uid.get_uid ();
		screenshot_path = @"$dir/$uid.png";

		return screenshot_path;
	}

	private void save_screenshot () throws Error {
		if (!core.supports_serialization ())
			return;

		var pixbuf = view.pixbuf;
		if (pixbuf == null)
			return;

		var screenshot_path = get_screenshot_path ();

		var now = new GLib.DateTime.now_local ();
		var creation_time = now.to_string ();
		var platform = core_source.get_platform ();
		var platform_name = RetroPlatform.get_platform_name (platform);
		var title = game_title.get_title ();

		var x_dpi = pixbuf.get_option("x-dpi") ?? "";
		var y_dpi = pixbuf.get_option("y-dpi") ?? "";

		// See http://www.libpng.org/pub/png/spec/iso/index-object.html#11textinfo
		// for description of used keys. "Game Title" and "Platform" are
		// non-standard fields as allowed by PNG specification.
		pixbuf.save (screenshot_path, "png",
		             "tEXt::Software", "GNOME Games",
		             "tEXt::Title", @"Screenshot of $title on $platform_name",
		             "tEXt::Creation Time", creation_time.to_string (),
		             "tEXt::Game Title", title,
		             "tEXt::Platform", platform_name,
		             "x-dpi", x_dpi,
		             "y-dpi", y_dpi,
		             null);
	}

	private void load_screenshot () throws Error {
		if (!core.supports_serialization ())
			return;

		var screenshot_path = get_screenshot_path ();

		if (!FileUtils.test (screenshot_path, FileTest.EXISTS))
			return;

		var pixbuf = new Gdk.Pixbuf.from_file (screenshot_path);
		view.pixbuf = pixbuf;
	}

	private bool on_shutdown () {
		stop ();

		return true;
	}

	private static void try_make_dir (string path) {
		var file = File.new_for_path (path);
		try {
			if (!file.query_exists ())
				file.make_directory_with_parents ();
		}
		catch (Error e) {
			warning (@"$(e.message)\n");

			return;
		}
	}

	private string get_unsupported_system_message () {
		if (core_source != null) {
			var platform = core_source.get_platform ();
			var platform_name = RetroPlatform.get_platform_name (platform);
			if (platform_name != null)
				return _("The system “%s” isn’t supported yet, but full support is planned.").printf (platform_name);
		}

		return _("The system isn’t supported yet, but full support is planned.");
	}
}
