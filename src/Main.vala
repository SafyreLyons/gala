//  
//  Copyright (C) 2012 Tom Beckmann, Rico Tzschichholz
// 
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
// 
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
// 
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
// 

using Meta;

namespace Gala
{
	public enum InputArea {
		NONE,
		FULLSCREEN,
		HOT_CORNER
	}
	
	public class Plugin : Meta.Plugin
	{
		WindowSwitcher winswitcher;
		WorkspaceView workspace_view;
		
		Window? moving; //place for the window that is being moved over
		
		internal Gee.LinkedList<Clutter.Actor> minimizing;
		internal Gee.LinkedList<Clutter.Actor> maximizing;
		internal Gee.LinkedList<Clutter.Actor> unmaximizing;
		internal Gee.LinkedList<Clutter.Actor> mapping;
		internal Gee.LinkedList<Clutter.Actor> destroying;
		
		public Plugin ()
		{
			Prefs.override_preference_schema ("attach-modal-dialogs", SCHEMA+".appearance");
			Prefs.override_preference_schema ("button-layout", SCHEMA+".appearance");
			Prefs.override_preference_schema ("edge-tiling", SCHEMA+".behavior");
			Prefs.override_preference_schema ("enable-animations", SCHEMA+".animations");
			Prefs.override_preference_schema ("theme", SCHEMA+".appearance");
		}
		
		public override void start ()
		{
			var screen = get_screen ();
			
			var stage = Compositor.get_stage_for_screen (screen);
			screen.override_workspace_layout (ScreenCorner.TOPLEFT, false, 4, -1);
			
			workspace_view = new WorkspaceView (this);
			workspace_view.visible = false;
			winswitcher = new WindowSwitcher (this);
			
			stage.add_child (workspace_view);
			stage.add_child (winswitcher);
			
			minimizing = new Gee.LinkedList<Clutter.Actor> ();
			maximizing = new Gee.LinkedList<Clutter.Actor> ();
			unmaximizing = new Gee.LinkedList<Clutter.Actor> ();
			mapping = new Gee.LinkedList<Clutter.Actor> ();
			destroying = new Gee.LinkedList<Clutter.Actor> ();
			
			/*keybindings*/
			KeyBinding.set_custom_handler ("panel-main-menu", () => {
				try {
					Process.spawn_command_line_async (
						BehaviorSettings.get_default ().panel_main_menu_action);
				} catch (Error e) { warning (e.message); }
			});
			
			KeyBinding.set_custom_handler ("toggle-recording", () => {
				try {
					Process.spawn_command_line_async (
						BehaviorSettings.get_default ().toggle_recording_action);
				} catch (Error e) { warning (e.message); }
			});
			
			KeyBinding.set_custom_handler ("show-desktop", () => {
				workspace_view.show ();
			});
			
			KeyBinding.set_custom_handler ("switch-windows", winswitcher.handle_switch_windows);
			KeyBinding.set_custom_handler ("switch-windows-backward", winswitcher.handle_switch_windows);
			
			KeyBinding.set_custom_handler ("switch-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("switch-to-workspace-left", workspace_view.handle_switch_to_workspace);
			KeyBinding.set_custom_handler ("switch-to-workspace-right", workspace_view.handle_switch_to_workspace);
			
			KeyBinding.set_custom_handler ("move-to-workspace-up", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-down", () => {});
			KeyBinding.set_custom_handler ("move-to-workspace-left",  (d, s, w) => move_window (w, true) );
			KeyBinding.set_custom_handler ("move-to-workspace-right", (d, s, w) => move_window (w, false) );
			
			/*shadows*/
			reload_shadow ();
			
			ShadowSettings.get_default ().notify.connect (reload_shadow);
			
			/*hot corner*/
			int width, height;
			screen.get_size (out width, out height);
			
			var hot_corner = new Clutter.Rectangle ();
			hot_corner.x = width - 1;
			hot_corner.y = height - 1;
			hot_corner.width = 1;
			hot_corner.height = 1;
			hot_corner.opacity = 0;
			hot_corner.reactive = true;
			
			hot_corner.enter_event.connect (() => {
				workspace_view.show ();
				return false;
			});
			
			stage.add_child (hot_corner);
			
			update_input_area ();
			BehaviorSettings.get_default ().notify["enable-manager-corner"].connect (update_input_area);
		}
		
		public void update_input_area ()
		{
			if (BehaviorSettings.get_default ().enable_manager_corner)
				set_input_area (InputArea.HOT_CORNER);
			else
				set_input_area (InputArea.NONE);
		}
		
		/*to be called when the shadow settings have been changed*/
		public void reload_shadow ()
		{
			var factory = ShadowFactory.get_default ();
			var settings = ShadowSettings.get_default ();
			Meta.ShadowParams shadow;
			
			//normal focused
			shadow = settings.get_shadowparams ("normal_focused");
			factory.set_params ("normal", true, shadow);
			
			//normal unfocused
			shadow = settings.get_shadowparams ("normal_unfocused");
			factory.set_params ("normal", false, shadow);
			
			//menus
			shadow = settings.get_shadowparams ("menu");
			factory.set_params ("menu", false, shadow);
			factory.set_params ("dropdown-menu", false, shadow);
			factory.set_params ("popup-menu", false, shadow);
			
			//dialog focused
			shadow = settings.get_shadowparams ("dialog_focused");
			factory.set_params ("dialog", true, shadow);
			factory.set_params ("modal_dialog", false, shadow);
			
			//dialog unfocused
			shadow = settings.get_shadowparams ("normal_unfocused");
			factory.set_params ("dialog", false, shadow);
			factory.set_params ("modal_dialog", false, shadow);
		}
		
		/**
		 * returns a pixbuf for the application of this window or a default icon
		 **/
		public static Gdk.Pixbuf get_icon_for_window (Window window, int size)
		{
			unowned Gtk.IconTheme icon_theme = Gtk.IconTheme.get_default ();
			Gdk.Pixbuf? image = null;
			
			var app = Bamf.Matcher.get_default ().get_application_for_xid ((uint32)window.get_xwindow ());
			if (app != null && app.get_desktop_file () != null) {
				try {
					var appinfo = new DesktopAppInfo.from_filename (app.get_desktop_file ());
					if (appinfo != null) {
						var iconinfo = icon_theme.lookup_by_gicon (appinfo.get_icon (), size, 0);
						if (iconinfo != null)
							image = iconinfo.load_icon ();
					}
				} catch (Error e) {
					warning (e.message);
				}
			}
			
			if (image == null) {
				try {
					image = icon_theme.load_icon ("application-default-icon", size, 0);
				} catch (Error e) {
					warning (e.message);
				}
			}
			
			if (image == null) {
				image = new Gdk.Pixbuf (Gdk.Colorspace.RGB, true, 8, 1, 1);
				image.fill (0x00000000);
			}
			
			return image;
		}
		
		public Window get_next_window (Meta.Workspace workspace, bool backward=false)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			
			var window = display.get_tab_next (Meta.TabList.NORMAL, screen, 
				screen.get_active_workspace (), null, backward);
			
			if (window == null)
				window = display.get_tab_current (Meta.TabList.NORMAL, screen, workspace);
			
			return window;
		}
		
		/**
		 * set the area where clutter can receive events
		 **/
		public void set_input_area (InputArea area)
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			
			X.Xrectangle rect;
			int width, height;
			screen.get_size (out width, out height);
			
			switch (area) {
				case InputArea.FULLSCREEN:
					rect = {0, 0, (ushort)width, (ushort)height};
					break;
				case InputArea.HOT_CORNER: //leave one pix in the bottom left
					rect = {(short)(width - 1), (short)(height - 1), 1, 1};
					break;
				default:
					Util.empty_stage_input_region (screen);
					return;
			}
			
			var xregion = X.Fixes.create_region (display.get_xdisplay (), {rect});
			Util.set_stage_input_region (screen, xregion);
		}
		
		void move_window (Window? window, bool reverse)
		{
			if (window == null)
				return;
			
			var screen = get_screen ();
			var display = screen.get_display ();
			
			var idx = screen.get_active_workspace ().index () + (reverse ? -1 : 1);
			
			if (idx < 0 || idx >= screen.n_workspaces)
				return;
			
			if (!window.is_on_all_workspaces ())
				window.change_workspace_by_index (idx, false, display.get_current_time ());
			
			moving = window;
			screen.get_workspace_by_index (idx).activate_with_focus (window, display.get_current_time ());
		}
		
		public new void begin_modal ()
		{
			var screen = get_screen ();
			var display = screen.get_display ();
			
			base.begin_modal (x_get_stage_window (Compositor.get_stage_for_screen (screen)), {}, 0, display.get_current_time ());
		}
		
		public new void end_modal ()
		{
			base.end_modal (get_screen ().get_display ().get_current_time ());
		}
		
		public void get_current_cursor_position (out int x, out int y)
		{
			Gdk.Display.get_default ().get_device_manager ().get_client_pointer ().get_position (null, 
				out x, out y);
		}
		
		public void dim_window (Window window, bool dim)
		{
			var win = window.get_compositor_private () as Clutter.Actor;
			if (dim) {
				if (win.has_effects ())
					return;
				win.add_effect_with_name ("darken", new Clutter.ColorizeEffect ({180, 180, 180, 255}));
			} else
				win.clear_effects ();
		}
		
		/*
		 * effects
		 */
		
		public override void minimize (WindowActor actor)
		{
			minimize_completed (actor);
		}
		
		//stolen from original mutter plugin
		public override void maximize (WindowActor actor, int ex, int ey, int ew, int eh)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				maximize_completed (actor);
				return;
			}
			
			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				add_animator (ref maximizing, actor);
				
				float x, y, width, height;
				actor.get_size (out width, out height);
				actor.get_position (out x, out y);
				
				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);
				
				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().snap_duration, 
					scale_x:scale_x, scale_y:scale_y).completed.connect ( () => {
					
					actor.animate (Clutter.AnimationMode.LINEAR, 1, scale_x:1.0f, 
						scale_y:1.0f);//just scaling didnt want to work..
					
					if (end_animation (ref maximizing, actor))
						maximize_completed (actor);
				});
				
				return;
			}
			
			maximize_completed (actor);
		}
		
		public override void map (WindowActor actor)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				map_completed (actor);
				return;
			}
			
			add_animator (ref mapping, actor);
			
			var screen = get_screen ();
			var display = screen.get_display ();
			var window = actor.get_meta_window ();
			
			var rect = window.get_outer_rect ();
			int width, height;
			screen.get_size (out width, out height);
			
			if (window.window_type == WindowType.NORMAL) {
				
				if (rect.x < 100 && rect.y < 100) { //guess the window is placed at a bad spot
					window.move_frame (true, (int)(width/2.0f - rect.width/2.0f), 
						(int)(height/2.0f - rect.height/2.0f));
					actor.x = width/2.0f - rect.width/2.0f - 10;
					actor.y = height/2.0f - rect.height/2.0f - 10;
				}
			}
			
			actor.show ();
			
			switch (window.window_type) {
				case WindowType.NORMAL:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, 0, 10};
					actor.scale_x = 0.2f;
					actor.scale_y = 0.2f;
					actor.opacity = 0;
					actor.rotation_angle_x = 40.0f;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, AnimationSettings.get_default ().open_duration, 
						scale_x:1.0f, scale_y:1.0f, rotation_angle_x:0.0f, opacity:255)
						.completed.connect ( () => {
						
						if (end_animation (ref mapping, actor))
							map_completed (actor);
						window.activate (display.get_current_time ());
					});
					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, 0, 10};
					actor.scale_x = 0.9f;
					actor.scale_y = 0.9f;
					actor.opacity = 0;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 150, 
						scale_x:1.0f, scale_y:1.0f, opacity:255)
						.completed.connect ( () => {
						
						if (end_animation (ref mapping, actor))
							map_completed (actor);
						
						if (!window.is_override_redirect ())
							window.activate (display.get_current_time ());
					});
					break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:
					actor.scale_gravity = Clutter.Gravity.NORTH;
					actor.scale_x = 1.0f;
					actor.scale_y = 0.0f;
					actor.opacity = 0;
					
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 150, 
						scale_y:1.0f, opacity:255).completed.connect ( () => {
						
						if (end_animation (ref mapping, actor))
							map_completed (actor);
					});
					
					if (AppearanceSettings.get_default ().dim_parents &&
						window.window_type == WindowType.MODAL_DIALOG && 
						window.is_attached_dialog ())
						dim_window (window.find_root_ancestor (), true);
					
					break;
				default:
					if (end_animation (ref mapping, actor))
						map_completed (actor);
					break;
			}
		}
		
		public override void destroy (WindowActor actor)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				destroy_completed (actor);
				return;
			}
			
			var screen = get_screen ();
			var display = screen.get_display ();
			var window = actor.get_meta_window ();
			
			add_animator (ref destroying, actor);
			
			switch (window.window_type) {
				case WindowType.NORMAL:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.rotation_center_x = {0, actor.height, 10};
					actor.show ();
					actor.animate (Clutter.AnimationMode.EASE_IN_QUAD, AnimationSettings.get_default ().close_duration, 
						scale_x:0.95f, scale_y:0.95f, opacity:0, rotation_angle_x:15.0f)
						.completed.connect ( () => {
						var focus = display.get_tab_current (Meta.TabList.NORMAL, screen, screen.get_active_workspace ());
						// Only switch focus to the next window if none has grabbed it already
						if (focus == null) {
							focus = get_next_window (screen.get_active_workspace ());
							if (focus != null)
								focus.activate (display.get_current_time ());
						}
						
						if (end_animation (ref destroying, actor))
							destroy_completed (actor);
					});
					break;
				case WindowType.MENU:
				case WindowType.DROPDOWN_MENU:
				case WindowType.POPUP_MENU:
					actor.scale_gravity = Clutter.Gravity.CENTER;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 200, 
						scale_x:0.9f, scale_y:0.9f, opacity:0).completed.connect ( () => {
						
						if (end_animation (ref destroying, actor))
							destroy_completed (actor);
					});
					break;
				case WindowType.MODAL_DIALOG:
				case WindowType.DIALOG:
					actor.scale_gravity = Clutter.Gravity.NORTH;
					actor.animate (Clutter.AnimationMode.EASE_OUT_QUAD, 200, 
						scale_y:0.0f, opacity:0).completed.connect ( () => {
						
						if (end_animation (ref destroying, actor))
							destroy_completed (actor);
					});
					
					dim_window (window.find_root_ancestor (), false);
					
					break;
				default:
					if (end_animation (ref destroying, actor))
						destroy_completed (actor);
					break;
			}
		}
		
		public override void unmaximize (Meta.WindowActor actor, int ex, int ey, int ew, int eh)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				unmaximize_completed (actor);
				return;
			}
			
			if (actor.get_meta_window ().window_type == WindowType.NORMAL) {
				add_animator (ref unmaximizing, actor);
				
				float x, y, width, height;
				actor.get_size (out width, out height);
				actor.get_position (out x, out y);
				
				float scale_x  = (float)ew  / width;
				float scale_y  = (float)eh / height;
				float anchor_x = (float)(x - ex) * width  / (ew - width);
				float anchor_y = (float)(y - ey) * height / (eh - height);
				
				actor.move_anchor_point (anchor_x, anchor_y);
				actor.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().snap_duration, 
					scale_x:scale_x, scale_y:scale_y).completed.connect ( () => {
					actor.move_anchor_point_from_gravity (Clutter.Gravity.NORTH_WEST);
					actor.animate (Clutter.AnimationMode.LINEAR, 1, scale_x:1.0f, 
						scale_y:1.0f);//just scaling didnt want to work..
					
					if (end_animation (ref unmaximizing, actor))
						unmaximize_completed (actor);
				});
				
				return;
			}
			
			unmaximize_completed (actor);
		}
		
		//add actor to list and check if he's already in there..
		void add_animator (ref Gee.LinkedList<Clutter.Actor> list, WindowActor actor)
		{
			list.add (actor);
		}
		
		//kill everything on actor if it's doing something, true if we did
		bool end_animation (ref Gee.LinkedList<Clutter.Actor> list, WindowActor actor)
		{
			var index = list.index_of (actor);
			if (index >= 0) {
				actor.detach_animation ();
				actor.opacity = 255;
				actor.scale_x = 1.0f;
				actor.scale_y = 1.0f;
				actor.rotation_angle_x = 0.0f;
				actor.anchor_gravity = Clutter.Gravity.NORTH_WEST;
				actor.scale_gravity = Clutter.Gravity.NORTH_WEST;
				
				print ("BEF LEN: %u\n", list.size);
				list.remove_at (index);
				print ("AFT LEN: %u\n", list.size);
				
				return true;
			} else { //there might have gone something lost, check
				foreach (var w in list) {
					bool found = false;
					foreach (var a in Compositor.get_window_actors (get_screen ())) {
						if (w == a)
							found = false;
					}
					if (!found)
						list.remove (w);
				}
			}
			
			return false;
		}
		
		public override void kill_window_effects (WindowActor actor)
		{
			if (end_animation (ref mapping, actor)) {
				map_completed (actor);
				print ("KILLED MAPPING ONE\n");
			}
			if (end_animation (ref minimizing, actor))
				minimize_completed (actor);
			if (end_animation (ref maximizing, actor))
				maximize_completed (actor);
			if (end_animation (ref unmaximizing, actor))
				unmaximize_completed (actor);
			if (end_animation (ref destroying, actor))
				destroy_completed (actor);
		}
		
		
		public void kill_all_running_effects ()
		{
			foreach (var it in mapping)
				kill_window_effects (it as WindowActor);
			foreach (var it in minimizing)
				kill_window_effects (it as WindowActor);
			foreach (var it in maximizing)
				kill_window_effects (it as WindowActor);
			foreach (var it in unmaximizing)
				kill_window_effects (it as WindowActor);
			foreach (var it in destroying)
				kill_window_effects (it as WindowActor);
		}
		
		/*workspace switcher*/
		GLib.List<Meta.WindowActor>? win;
		GLib.List<Clutter.Actor>? par; //class space for kill func
		Clutter.Actor in_group;
		Clutter.Actor out_group;
		Clutter.Clone wallpaper;
		
		public override void switch_workspace (int from, int to, MotionDirection direction)
		{
			if (!AnimationSettings.get_default ().enable_animations) {
				switch_workspace_completed ();
				return;
			}
			
			unowned List<WindowActor> windows = Compositor.get_window_actors (get_screen ());
			float w, h;
			get_screen ().get_size (out w, out h);
			
			var x2 = 0.0f; var y2 = 0.0f;
			if (direction == MotionDirection.UP ||
				direction == MotionDirection.UP_LEFT ||
				direction == MotionDirection.UP_RIGHT)
				x2 = w;
			else if (direction == MotionDirection.DOWN ||
				direction == MotionDirection.DOWN_LEFT ||
				direction == MotionDirection.DOWN_RIGHT)
				x2 = -w;
			
			in_group  = new Clutter.Actor ();
			out_group = new Clutter.Actor ();
			
			var group = Compositor.get_window_group_for_screen (get_screen ());
			
			var bg = Compositor.get_background_actor_for_screen (get_screen ());
			wallpaper = new Clutter.Clone (bg);
			
			wallpaper.x = (x2<0)?w:-w;
			
			bg.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 
				AnimationSettings.get_default ().workspace_switch_duration, x:(x2<0)?-w:w);
			wallpaper.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, 
				AnimationSettings.get_default ().workspace_switch_duration, x:0.0f);
			
			group.add_child (wallpaper);
			
			group.add_actor (in_group);
			group.add_actor (out_group);
			
			win = new List<Meta.WindowActor> ();
			par = new List<Clutter.Actor> ();
			
			WindowActor moving_actor = null;
			if (moving != null) {
				moving_actor = moving.get_compositor_private () as WindowActor;
				
				win.append (moving_actor);
				par.append (moving_actor.get_parent ());
				
				clutter_actor_reparent (moving_actor, Compositor.get_overlay_group_for_screen (get_screen ()));
			}
			
			for (var i=0;i<windows.length ();i++) {
				var window = windows.nth_data (i);
				if (!window.get_meta_window ().showing_on_its_workspace () || 
					moving != null && window == moving_actor)
					continue;
				
				if (window.get_workspace () == from) {
					win.append (window);
					par.append (window.get_parent ());
					clutter_actor_reparent (window, out_group);
				} else if (window.get_workspace () == to) {
					win.append (window);
					par.append (window.get_parent ());
					clutter_actor_reparent (window, in_group);
				} else if (window.get_meta_window ().window_type == WindowType.DOCK) {
					win.append (window);
					par.append (window.get_parent ());
					clutter_actor_reparent (window, Compositor.get_overlay_group_for_screen (get_screen ()));
				}
			}
			in_group.set_position (-x2, -y2);
			group.set_child_above_sibling (in_group, null);
			
			out_group.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().workspace_switch_duration,
				x:x2, y:y2);
			in_group.animate (Clutter.AnimationMode.EASE_IN_OUT_SINE, AnimationSettings.get_default ().workspace_switch_duration,
				x:0.0f, y:0.0f).completed.connect ( () => {
				end_switch_workspace ();
			});
		}
		
		void end_switch_workspace ()
		{
			if (win == null || par == null)
				return;
			
			var screen = get_screen ();
			var display = screen.get_display ();
			
			for (var i=0;i<win.length ();i++) {
				var window = win.nth_data (i);
				if (window.is_destroyed ())
					continue;
				if (window.get_parent () == out_group) {
					clutter_actor_reparent (window, par.nth_data (i));
					window.hide ();
				} else
					clutter_actor_reparent (window, par.nth_data (i));
			}
			
			win = null;
			par = null;
			
			if (in_group != null) {
				in_group.destroy ();
			}
			
			if (out_group != null) {
				out_group.destroy ();
			}
			
			var bg = Compositor.get_background_actor_for_screen (get_screen ());
			bg.detach_animation ();
			bg.x = 0.0f;
			wallpaper.destroy ();
			wallpaper = null;
			
			switch_workspace_completed ();
			
			moving = null;
			
			var focus = display.get_tab_current (Meta.TabList.NORMAL, screen, screen.get_active_workspace ());
			// Only switch focus to the next window if none has grabbed it already
			if (focus == null) {
				focus = get_next_window (screen.get_active_workspace ());
				if (focus != null)
					focus.activate (display.get_current_time ());
			}
			
		}
		
		public override void kill_switch_workspace ()
		{
			end_switch_workspace ();
		}
		
		public override bool xevent_filter (X.Event event)
		{
			return x_handle_event (event) != 0;
		}
		
		public override PluginInfo plugin_info ()
		{
			return {"Gala", Gala.VERSION, "Tom Beckmann", "GPLv3", "A nice window manager"};
		}
		
	}
	
	const string VERSION = "0.1";
	const string SCHEMA = "org.pantheon.desktop.gala";
	
	const OptionEntry[] OPTIONS = {
		{ "version", 0, OptionFlags.NO_ARG, OptionArg.CALLBACK, (void*) print_version, "Print version", null },
		{ null }
	};
	
	void print_version () {
		stdout.printf ("Gala %s\n", Gala.VERSION);
		Meta.exit (Meta.ExitCode.SUCCESS);
	}

	static void clutter_actor_reparent (Clutter.Actor actor, Clutter.Actor new_parent)
	{
		if (actor == new_parent)
			return;
		
		actor.ref ();
		actor.get_parent ().remove_child (actor);
		new_parent.add_child (actor);
		actor.unref ();
	}
	
	[CCode (cname="clutter_x11_handle_event")]
	public extern int x_handle_event (X.Event xevent);
	[CCode (cname="clutter_x11_get_stage_window")]
	public extern X.Window x_get_stage_window (Clutter.Actor stage);
	
	int main (string [] args) {
		
		unowned OptionContext ctx = Meta.get_option_context ();
		ctx.add_main_entries (Gala.OPTIONS, null);
		try {
		    ctx.parse (ref args);
		} catch (Error e) {
		    stderr.printf ("Error initializing: %s\n", e.message);
		    Meta.exit (Meta.ExitCode.ERROR);
		}
		
#if HAS_MUTTER36
		Meta.Plugin.manager_set_plugin_type (new Gala.Plugin ().get_type ());
#else		
		Meta.Plugin.type_register (new Gala.Plugin ().get_type ());
#endif
		
		/**
		 * Prevent Meta.init () from causing gtk to load gail and at-bridge
		 * Taken from Gnome-Shell main.c
		 */
		GLib.Environment.set_variable ("NO_GAIL", "1", true);
		GLib.Environment.set_variable ("NO_AT_BRIDGE", "1", true);
		Meta.init ();
		GLib.Environment.unset_variable ("NO_GAIL");
		GLib.Environment.unset_variable ("NO_AT_BRIDGE");
		
		return Meta.run ();
	}
}