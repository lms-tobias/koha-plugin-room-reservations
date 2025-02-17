package Koha::Plugin::Com::MarywoodUniversity::RoomReservations;

use Modern::Perl;

use base qw(Koha::Plugins::Base);

use Carp;
use Cwd qw( abs_path cwd );
use File::Basename qw( dirname );
use MIME::Base64;
use MIME::QuotedPrint;
use Mail::Sendmail;
use POSIX 'strftime';

use C4::Auth;
use C4::Context;
use C4::Output;
use Koha::DateUtils;
use Koha::Email;
use Koha::Patrons;
use Encode;

use Locale::Messages;;
Locale::Messages->select_package('gettext_pp');

use Locale::Messages qw(:locale_h :libintl_h);
use POSIX qw(setlocale);

our $VERSION = "{VERSION}";

## Table names and associated MySQL indexes
#
our $rooms_table = 'booking_rooms';
our $rooms_index = 'bookingrooms_idx';
our $bookings_table = 'bookings';
our $bookings_index = 'booking_idx';
our $openinghours_table = 'booking_opening_hours';
our $openinghours_index = 'bookingopeninghours_idx';
our $equipment_table = 'booking_equipment';
our $equipment_index = 'bookingequipment_idx';
our $roomequipment_table = 'booking_room_equipment';
our $roomequipment_index = 'bookingroomequipment_idx';

# set locale settings for gettext
#my $self = new('Koha::Plugin::Com::MarywoodUniversity::RoomReservations');
#my $cgi = $self->{'cgi'};

#my $locale = C4::Languages::getlanguage($cgi);
#$locale = substr( $locale, 0, 2 );
#$ENV{'LANGUAGE'} = $locale;
#setlocale Locale::Messages::LC_ALL(), '';
#textdomain "com.marywooduniversity.roomreservations";

#my $locale_path = abs_path( $self->mbf_path( 'translations' ) );
#bindtextdomain "com.marywooduniversity.roomreservations" => $locale_path;

our $metadata = {
    name            => getTranslation('Room Reservations Plugin'),
    author          => 'Lee Jamison',
    description     => getTranslation('This plugin provides a room reservation solution on both intranet and OPAC interfaces.'),
    date_authored   => '2017-05-08',
    date_updated    => '1900-01-01',
    minimum_version => '3.22',
    maximum_version => undef,
    version         => $VERSION,
};

our $valid; # used to check if booking still valid prior to insertion of new booking

sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## NOTE: install() uses an array of double-q commands and
## a for loop of dbh statement execution in order to
## prevent MySQL syntax errors triggered from multiple
## $dbh->do statements

## the first double-q command uses a compound
## DROP TABLE IF EXISTS statement to prevent
## a MySQL syntax error
sub install() {
    my ( $self, $args ) = @_;

    my $original_version = $self->retrieve_data('plugin_version'); # is this a new install or an upgrade?

    my @installer_statements = (
        qq{DROP TABLE IF EXISTS $bookings_table, $roomequipment_table, $equipment_table, $rooms_table, $openinghours_table},
        qq{CREATE TABLE $rooms_table (
              `roomid` INT NOT NULL AUTO_INCREMENT,
              `roomnumber` VARCHAR(20) NOT NULL, -- alphanumeric room identifier
              `maxcapacity` INT NOT NULL, -- maximum number of people allowed in the room
              `description` TEXT, -- room description to display in OPAC
            PRIMARY KEY (roomid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $rooms_index ON $rooms_table(roomid);},
        qq{CREATE TABLE $bookings_table (
              `bookingid` INT NOT NULL AUTO_INCREMENT,
              `borrowernumber` INT NOT NULL, -- foreign key; borrowers table
              `roomid` INT NOT NULL, -- foreign key; $rooms_table table
              `start` DATETIME NOT NULL, -- start date/time of booking
              `end` DATETIME NOT NULL, -- end date/time of booking
              `blackedout` TINYINT(1) NOT NULL DEFAULT 0,
              PRIMARY KEY (bookingid),
              CONSTRAINT calendar_icfk FOREIGN KEY (roomid) REFERENCES $rooms_table(roomid),
              CONSTRAINT calendar_ibfk FOREIGN KEY (borrowernumber) REFERENCES borrowers(borrowernumber)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $bookings_index ON $bookings_table(borrowernumber, roomid);},
        qq{CREATE TABLE $openinghours_table (
              `openid` INT NOT NULL AUTO_INCREMENT,
              `day` INT NOT NULL,
              `start` TIME NOT NULL, -- start date/time of opening hours
              `end` TIME NOT NULL, -- end date/time of opening hours
              PRIMARY KEY (openid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $openinghours_index ON $openinghours_table(openid);},
        qq{CREATE TABLE $equipment_table (
              `equipmentid` INT NOT NULL AUTO_INCREMENT,
              `equipmentname` VARCHAR(20) NOT NULL,
              PRIMARY KEY (equipmentid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $equipment_index ON $equipment_table(equipmentid);},
        qq{CREATE TABLE $roomequipment_table (
              `roomid` INT NOT NULL,
              `equipmentid` INT NOT NULL,
              PRIMARY KEY (roomid, equipmentid),
              CONSTRAINT roomequipment_iafk FOREIGN KEY (roomid) REFERENCES $rooms_table(roomid),
              CONSTRAINT roomequipment_ibfk FOREIGN KEY (equipmentid) REFERENCES $equipment_table(equipmentid)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;},
        qq{CREATE INDEX $roomequipment_index ON $roomequipment_table(roomid, equipmentid);},
        qq{INSERT INTO $equipment_table (equipmentname) VALUES ('none');},
    );

    if (!defined($original_version)) { # clean install

        # Add required IntranetUserJS entry to place
    # reservations for a patron from circulation.pl
    my $IntranetUserJS = C4::Context->preference('IntranetUserJS');

    $IntranetUserJS =~ s/\/\* JS for Koha RoomReservation Plugin.*End of JS for Koha RoomReservation Plugin \*\///gs;

    $IntranetUserJS .= q[/* JS for Koha RoomReservation Plugin
This JS was added automatically by installing the RoomReservation plugin
Please do not modify */

$(document).ready(function() {
var buttonText = "];
$IntranetUserJS .= getTranslation('Reserve room as patron').q[";
var data = $("div.patroninfo h5").html();

    if (typeof borrowernumber !== 'undefined') {
        if (data) {
            var regExp = /\(([^)]+)\)/;
            var matches = regExp.exec(data);
            var cardnumber = matches[1];

            $('<a id="bookAsButton" target="_blank" class="btn btn-default btn-sm" href="/cgi-bin/koha/plugins/run.pl?class=Koha::Plugin::Com::MarywoodUniversity::RoomReservations&method=bookas&borrowernumber=' + borrowernumber + '"><i class="fa fa-search"></i>&nbsp;' + buttonText + '</a>').insertAfter($('#addnewmessageLabel'));
        }
    }
});

    /* End of JS for Koha RoomReservation Plugin */];

        C4::Context->set_preference( 'IntranetUserJS', $IntranetUserJS );

        for (@installer_statements) {
            my $sth = C4::Context->dbh->prepare($_);
            $sth->execute or die C4::Context->dbh->errstr;
        }
    }
    else { # upgrade
        if ($original_version eq '1.1.15') {
            # do nothing..no database changes
        }
    }

    $self->store_data({ plugin_version => $VERSION }); # used when upgrading to newer version

    return 1;
}

sub uninstall() {
    my ( $self, $args ) = @_;

    ## The order of this list is intentional
    ## otherwise the DROP commands will fail
    ## due to foreign key constraints
    ## preventing deletion
    ##
    ## NOTE: the order of dropping is the reverse
    ## of the install() method's order

    my @uninstaller_statements = (
        qq{DROP TABLE IF EXISTS $bookings_table;},
        qq{DROP TABLE IF EXISTS $openinghours_table;},
        qq{DROP TABLE IF EXISTS $roomequipment_table;},
        qq{DROP TABLE IF EXISTS $equipment_table;},
        qq{DROP TABLE IF EXISTS $rooms_table;},
    );

    for (@uninstaller_statements) {
        my $sth = C4::Context->dbh->prepare($_);
        $sth->execute or die C4::Context->dbh->errstr;
    }

    return 1;
}

sub bookas {

    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'bookas.tt' });
    $template->param(
        language => C4::Languages::getlanguage($cgi) || 'en',
        mbf_path => abs_path( $self->mbf_path( 'translations' ) ),
    );

    my $op = $cgi->param('op') || q{};

    my $borrowernumber = $cgi->param('borrowernumber');

    my $member = Koha::Patrons->find( $borrowernumber );

    my $member_firstname = $member->firstname;
    my $member_surname = $member->surname;
    my $member_email = $member->email;

    my $submitButton = $cgi->param('confirmationSubmit') || q{};
    
    if ( $submitButton eq 'Start over' ) {

        $op = '';
    }

    $template->param(
        op             => $op,
        borrowernumber => $borrowernumber,
        firstname      => $member_firstname,
        surname        => $member_surname,
        email          => $member_email,
    );

    if ( $op eq '' ) {
       
        my $equipment = loadAllEquipment();
        my $rooms = getAllRooms();

        my $submitCheckRoomAvailability = $cgi->param('submit-check-room-availability') || q{};
        
        if ($submitCheckRoomAvailability ne '') {
		
			my $start_date = $cgi->param('availability-search-start-date');
			my $start_time = $cgi->param('availability-search-start-time');

			my $end_date = $cgi->param('availability-search-end-date');
			my $end_time = $cgi->param('availability-search-end-time');
			
			my $start_datetime = dt_from_string(sprintf("%s %s", $start_date, $start_time));
			my $end_datetime   = dt_from_string(sprintf("%s %s", $end_date, $end_time));
			
			my $room_id = $cgi->param('availability-search-room');
			
			my $roomIsAvailable = checkRoomAvailability($room_id, $start_datetime, $end_datetime);
			
			if ($roomIsAvailable != 0) {  # --> go to confirmation page
				my $displayed_start = output_pref({ dt => $start_datetime, }); 
				my $displayed_end = output_pref({ dt => $end_datetime, }); 

				my $displayed_event_time = "$displayed_start - $displayed_end";

				my $user_fn = C4::Context->userenv->{'firstname'} || q{};
				my $user_ln = C4::Context->userenv->{'surname'} || q{};
				my $user_bn = C4::Context->userenv->{'number'};

				my $user = "$user_fn $user_ln";
				my $email = C4::Context->userenv->{'emailaddress'};

				my $selectedRoomNumber = getRoomNumberById($room_id);
		
				$template->param(
					op                  => 'room-selection-confirmation',
					current_user        => $user,
					current_user_email  => $member_email,
					selected_room_id    => $room_id,
					selected_room_no    => $selectedRoomNumber,
					displayed_time      => $displayed_event_time,
					selected_start_time => $start_datetime,
					selected_end_time   => $end_datetime,
					displayed_start     => $displayed_start,
					displayed_end       => $displayed_end,
				);
			} else {  # --> room is not available: print warning
				$template->param(
					op => $op,
					room_checked => 0,
					rooms => $rooms,
					available_room_equipment => $equipment,
				);
			}
		} else {   # --> submit button not pressed, yet
			$template->param(
				op => $op,
				room_checked => -1,
				rooms => $rooms,
				available_room_equipment => $equipment,
			);
		}
    }
    elsif ( $op eq 'availability-search-results' ) {
        my $start_date = $cgi->param('availability-search-start-date');
        my $start_time = $cgi->param('availability-search-start-time');

        my $end_date = $cgi->param('availability-search-end-date');
        my $end_time = $cgi->param('availability-search-end-time');

        my $room_capacity = $cgi->param('availability-search-room-capacity');

        my @equipment = $cgi->param('availability-search-selected-equipment') || ();

        my $event_start = sprintf("%s %s", $start_date, $start_time);
        my $event_end   = sprintf("%s %s", $end_date, $end_time);

        # converts '/' to '-'
        (my $availability_format_start_date = $start_date) =~ s/\//\-/g;
        (my $availability_format_end_date = $end_date) =~ s/\//\-/g;

        # re-arranges from MM-DD-YYYY to YYYY-MM-DD
        ($availability_format_start_date = $availability_format_start_date) =~ s/(\d\d)-(\d\d)-(\d\d\d\d)/$3-$1-$2/;
        ($availability_format_end_date = $availability_format_end_date) =~ s/(\d\d)-(\d\d)-(\d\d\d\d)/$3-$1-$2/;

        # used exclusively for getAvailableRooms -- BUG excluding T from the DATETIME start/end field returns wrong results?
        my $availability_format_start = sprintf("%sT%s", $availability_format_start_date, $start_time);
        my $availability_format_end   = sprintf("%sT%s", $availability_format_end_date, $end_time);

        # generates a DateTime object from a string
        $event_start = dt_from_string($event_start);
        $event_end = dt_from_string($event_end);

        my $displayed_event_start = output_pref({ dt => $event_start, }); # dateformat => 'us', timeformat => '12hr' });
        my $displayed_event_end = output_pref({ dt => $event_end, }); #dateformat => 'us', timeformat => '12hr' });

        my $availableRooms = getAvailableRooms($availability_format_start, $availability_format_end, $room_capacity, \@equipment);

        # boolean -- returns 1 (one) if true or 0 (zero) if false
        my $roomsAreAvailable = areAnyRoomsAvailable($availableRooms);

        $template->param(
            available_rooms => $availableRooms,
            are_rooms_available => $roomsAreAvailable,
            displayed_start => $displayed_event_start,
            displayed_end => $displayed_event_end,
            event_start_time => $event_start,
            event_end_time => $event_end,
        );
    }
    elsif ( $op eq 'room-selection-confirmation' ) {
        my $selected_id = $cgi->param('selected-room-id');
        my $displayed_start = $cgi->param('displayed-start');
        my $displayed_end = $cgi->param('displayed-end');
        my $event_start = $cgi->param('event-start-time');
        my $event_end = $cgi->param('event-end-time');

        my $displayed_event_time = "$displayed_start - $displayed_end";

        my $user = "$member_firstname $member_surname";

        my $selectedRoomNumber = getRoomNumberById($selected_id);

        $template->param(
            op                  => $op,
            current_user        => $user,
            current_user_email  => $member_email,
            selected_room_id    => $selected_id,
            selected_room_no    => $selectedRoomNumber,
            displayed_time      => $displayed_event_time,
            selected_start_time => $event_start,
            selected_end_time   => $event_end,
            displayed_start     => $displayed_start,
            displayed_end       => $displayed_end,
        );
    }
    elsif ( $op eq 'reservation-confirmed' ) {
        my $roomid = $cgi->param('confirmed-room-id');
        my $start   = $cgi->param('confirmed-start');
        my $end     = $cgi->param('confirmed-end');
        my $sendCopy = $cgi->param('send-confirmation-copy');
        #my $submitButton = $cgi->param('confirmationSubmit');
        my $user = $cgi->param('confirmed-user');
        my $roomnumber = $cgi->param('confirmed-roomnumber');
        my $displayed_start = $cgi->param('confirmed-displayed-start');
        my $displayed_end = $cgi->param('confirmed-displayed-end');
        my $patronEmail = $cgi->param('confirmed-email');

        $valid = preBookingAvailabilityCheck($roomid, $start, $end);

        if ($valid) {
            addBooking($borrowernumber, $roomid, $start, $end);
        }
        else {
            $template->param(
                invalid_booking => 1,
            );
        }

    if ( $sendCopy eq '1' && $valid ) {

        my $email = Koha::Email->new();
        my $user_email = C4::Context->preference('KohaAdminEmailAddress');

        # KohaAdmin address is the default - no need to set
        my %mail = $email->create_message_headers({
            to => $patronEmail,
        });
        $mail{'X-Abuse-Report'} = C4::Context->preference('KohaAdminEmailAddress');

        # Since we are already logged in, no need to check credentials again
        # when loading a second template.
        my $template2 = $self->get_template({ file => 'calendar-sendconfirmation.tt' });
        $template->param(
            language => C4::Languages::getlanguage($cgi) || 'en',
            mbf_path => abs_path( $self->mbf_path( 'translations' ) ),
        );

        my $timestamp = getCurrentTimestamp();

        $template2->param(
            user => $user,
            room => $roomnumber,
            from => $displayed_start,
            to   => $displayed_end,
            confirmed_timestamp => $timestamp,
        );

        # Getting template result
        my $template_res = $template2->output();
        my $body;

        # Analysing information and getting mail properties

        if ($template_res =~ /<SUBJECT>(.*)<END_SUBJECT>/s) {
            $mail{subject} = $1;
            $mail{subject} =~ s|\n?(.*)\n?|$1|;
            $mail{subject} = Encode::encode("UTF-8", $mail{subject});
        }
        else { $mail{'subject'} = "no subject"; }

        my $email_header = "";

        if ( $template_res =~ /<HEADER>(.*)<END_HEADER>/s ) {
            $email_header = $1;
            $email_header =~ s|\n?(.*)\n?|$1|;
            $email_header = encode_qp(Encode::encode("UTF-8", $email_header));
        }

        my $email_file = "bookingconfirmation.txt";
        if ( $template_res =~ /<FILENAME>(.*)<END_FILENAME>/s ) {
            $email_file = $1;
            $email_file =~ s|\n?(.*)\n?|$1|;
        }

        if ( $template_res =~ /<MESSAGE>(.*)<END_MESSAGE>/s ) {
            $body = $1;
            $body =~ s|\n?(.*)\n?|$1|;
            $body = encode_qp(Encode::encode("UTF-8", $body));
        }

        $mail{body} = $body;

        my $boundary = "====" . time() . "====";

        $mail{'content-type'} = "multipart/mixed; boundary=\"$boundary\"";
        $boundary = '--' . $boundary;
        $mail{body} = <<END_OF_BODY;
$boundary
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable
$email_header
$body
$boundary--
END_OF_BODY

        # Sending mail (if not empty basket)
        if (sendmail %mail) {
            # do something if it works....
            $template->param(
                SENT      => "1",
                patron_email => $patronEmail,
            );
        }
        else {
            # do something if it doesnt work....
            carp "Error sending mail: an error has occurred";
            carp "Error sending mail: $Mail::Sendmail::error" if $Mail::Sendmail::error;
            $template->param( error => 1 );
        }
    }
    }

    print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    my $template = $self->get_template({ file => 'tool.tt' });
    $template->param(
        language => C4::Languages::getlanguage($cgi) || 'en',
        mbf_path => abs_path( $self->mbf_path( 'translations' ) ),
    );

    my $op = $cgi->param('op') || q{};
    my $tool_action = $cgi->param('tool_actions_selection');

    # used for manage blackouts
    my $manage_blackouts_submit = $cgi->param('manage-blackouts-submit') || q{}; # delete existing blackout
    my $submit_full_blackout = $cgi->param('submit-full-blackout') || q{}; # add full day blackout(s)
    my $submit_partial_blackout = $cgi->param('submit-partial-blackout') || q{}; # add partial-day blackout
    my $submit_opening_hours = $cgi->param('submit-opening-hours') || q{}; # add partial-day blackout
    my $submit_opening_hours_del = $cgi->param('submit-opening-hours-del') || q{}; # add partial-day blackout

    if ( $op eq 'action-selected' &&  $tool_action eq 'action-manage-reservations') {

        my $bookings = getAllBookings();

        $template->param(
            op => 'manage-reservations',
            bookings => $bookings,
        );
    }
    elsif ( $op eq 'action-selected' && $tool_action eq 'action-manage-blackouts' ) {

        my $blackouts = getAllBlackedoutBookings();

        my $rooms = getCurrentRoomNumbers();

        $template->param(
            op => 'manage-blackouts',
            blackouts => $blackouts,
            current_rooms => $rooms,
        );
    }
    elsif ( $op eq 'action-selected' && $tool_action eq 'action-manage-openings' ) {

        my $openingHours = getAllOpeningHours(1);
        
        $template->param(
			deleted => -1,
            op => 'manage-openings',
            opening_hours => $openingHours,
        );
    }
    elsif ( $op eq 'manage-openings' && $submit_opening_hours_del ne '' ) {
		
		my $selected = $cgi->param('manage-openings-action');
        my $selectedId = $cgi->param('manage-openings-id');
        my $deleted = -1;

        if ( $selected eq 'delete' ) {
            $deleted = deleteOpeningHoursById($selectedId);
        }

        my $openingHours = getAllOpeningHours(1);

        $template->param(
			deleted => $deleted,
            op => 'manage-openings',
            opening_hours => $openingHours,
        );
    }
    elsif ( $op eq 'manage-openings' &&  $submit_opening_hours ne '' ) {
		
		my $starttime = $cgi->param('opening-from');
		my $endtime = $cgi->param('opening-to');
		
		my @days = $cgi->param('weekdays');
		
		addOpeningHours(\@days, $starttime, $endtime);
		
		my $openingHours = getAllOpeningHours(1);
		
        $template->param(
            op => $op,
            opening_hours => $openingHours,
        );
    }
    elsif ( $op eq 'manage-reservations' ) {
        my $selected = $cgi->param('manage-bookings-action');

        my $selectedId = $cgi->param('manage-bookings-id');

        if ( $selected eq 'delete' ) {

            my $deleted = deleteBookingById($selectedId);

            my $bookings = getAllBookings();

            if ($deleted == 0) {
                $template->param(
                    deleted  => 1,
                    bookings => $bookings,
                );
            }
            else {
                $template->param(
                    deleted  => 0,
                    bookings => $bookings,
                );
            }
        }

        $template->param(
            op => $op,
        );
    }
    elsif ( $op eq 'manage-blackouts' &&  $manage_blackouts_submit ne '' ) {

        # TODO - delete the selected blackout

        my $bookingid = $cgi->param('manage-blackouts-id');

        deleteBookingById($bookingid);

        my $blackouts = getAllBlackedoutBookings();
        my $rooms = getCurrentRoomNumbers();

        $template->param(
            op => $op,
            blackouts => $blackouts,
            current_rooms => $rooms,
        );
    }
    elsif ( $op eq 'manage-blackouts' && $submit_full_blackout ne '' ) {

        my $blackout_start_date = $cgi->param('blackout-start-date');
        my $blackout_end_date = $cgi->param('blackout-end-date');
        my @rooms = $cgi->multi_param('current-room-blackout');

        my $start_date = $blackout_start_date . ' 00:00:00';
        my $end_date = $blackout_end_date . ' 23:59:59';

        my $current_user = C4::Context->userenv->{'number'};

        if ( $rooms[0] eq '0' ) {

            my $room_ids = getAllRoomIds(); # IDs of all rooms in rooms table

            my @room_IDs = @$room_ids;

            for my $item ( @room_IDs ) {
                for my $key ( keys %$item ) {
                    addBlackoutBooking($current_user, $item->{ $key }, $start_date, $end_date);
                }
            }
        }
        else {

            for (my $i = 0; $i < scalar(@rooms); $i++) {
                addBlackoutBooking($current_user, $rooms[$i], $start_date, $end_date);
            }
        }

        my $blackouts = getAllBlackedoutBookings();
        my $current_rooms = getCurrentRoomNumbers();

        $template->param(
            op => $op,
            blackouts => $blackouts,
            current_rooms => $current_rooms,
        );
    }
    elsif ( $op eq 'manage-blackouts' && $submit_partial_blackout ne '' ) {

        my $blackout_date = $cgi->param('blackout-date');
        my $start_time = $cgi->param('blackout-start-time');
        my $end_time = $cgi->param('blackout-end-time');
        my @rooms = $cgi->multi_param('current-room-blackout');

        #$blackout_date = sprintf '%3$04d-%02d-%02d', split m:/:, $blackout_date;

        my $start = "$blackout_date" . " $start_time";
        my $end = "$blackout_date" . " $end_time";

        my $current_user = C4::Context->userenv->{'number'};

        if ( $rooms[0] eq '0' ) {

            my $room_ids = getAllRoomIds(); # IDs of all rooms in rooms table

            my @room_IDs = @$room_ids;

            for my $item ( @room_IDs ) {
                for my $key ( keys %$item ) {
                    addBlackoutBooking($current_user, $item->{ $key }, $start, $end);
                }
            }
        }
        else {

            for (my $i = 0; $i < scalar(@rooms); $i++) {
                addBlackoutBooking($current_user, $rooms[$i], $start, $end);
            }
        }

        my $blackouts = getAllBlackedoutBookings();
        my $current_rooms = getCurrentRoomNumbers();

        $template->param(
            op => $op,
            blackouts => $blackouts,
            current_rooms => $current_rooms,
        );
    }

    print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();
}

sub configure {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};

    my $template = $self->get_template({ file => 'configure.tt' });
    $template->param(
        language => C4::Languages::getlanguage($cgi) || 'en',
        mbf_path => abs_path( $self->mbf_path( 'translations' ) ),
    );

    my $op = $cgi->param('op') || q{};

    if ( $op eq '' ) { # Displays currently configured rooms


        $template->param(

        );
    }
    elsif ( $op eq 'action-selected' ) {

        my $selected = $cgi->param('config_actions_selection');

        my $action = '';

        if ( $selected eq 'action-select-display' ) {

            $action = 'display-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-add' ) {


            $action = 'add-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-edit' ) {

            $action = 'edit-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-delete' ) {

            $action = 'delete-rooms';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-add-equipment' ) {

            $action = 'add-equipment';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-edit-equipment' ) {

            $action = 'edit-equipment-selection';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-select-delete-equipment' ) {

            $action = 'delete-equipment';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-max-future-date' ) {

            $action = 'max-future-date';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-max-time' ) {

            $action = 'max-time';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-restrict-categories' ) {

            $action = 'restrict-categories';

            $template->param(
                action => $action,
                op => $op,
            );
        }
        elsif ( $selected eq 'action-restrict-daily-reservations-per-patron' ) {

            $action = 'restrict-daily-reservations-per-patron';

            $template->param(
                action => $action,
                op => $op,
            );
        }
    }
    elsif ( $op eq 'restrict-daily-reservations-per-patron' ) {

        my $limit = $cgi->param('limit-submitted') || q{};

        if ($limit eq '1') {

            my $limit_count = $cgi->param('reservations-limit-field');

            $self->store_data({ count_limit => $limit_count });
        }

        my $current_limit = $self->retrieve_data('count_limit');

        if ( $current_limit eq '0' ) {
            $current_limit = '';
        }

        $template->param(
            op => $op,
            count_limit => $current_limit,
        );
    }
    elsif ( $op eq 'restrict-categories' ) {

        my $submitted = $cgi->param('restrict-categories-submitted') || q{};

        my $rest_message = $cgi->param('restricted-message');

        my $check_count;

        if ( $submitted eq '1' ) {

            my @restricted_categories_to_clear = $cgi->multi_param('currently-restricted-category');

            if (scalar(@restricted_categories_to_clear) > 0) {
                clearPatronCategoryRestriction(\@restricted_categories_to_clear);
            }
            else {
                clearPatronCategoryRestriction(undef);
            }

            my @categories_to_restrict = $cgi->multi_param('patron-category');

            for my $category (@categories_to_restrict) {

                # workaround to convert string to hash ref
                my %cat_hash;
                $cat_hash{qq(rcat_$category)} = $category;

                while ( my ( $key, $value ) = each %cat_hash ) {
                    $self->store_data({ $key => $value });
                }
            }


            # store restricted message
            $self->store_data({ restricted_message => $rest_message});
        }

        my $restricted = getRestrictedPatronCategories();

        my $searchfield = q||;

        my $categories = getPatronCategories();

        my $restricted_message = $self->retrieve_data('restricted_message');

        $template->param(
            op => $op,
            restricted_categories => $restricted,
            categories => $categories,
            restrict_message => $restricted_message,
        );
    }
    elsif ( $op eq 'max-time' ) {

        my $submitted = $cgi->param('max-submitted') || q{};

        if ( $submitted eq '1' ) {
			
			my $max_time_days = $cgi->param('max-time-days-field');
            my $max_time_hours = $cgi->param('max-time-hours-field');
            my $max_time_minutes = $cgi->param('max-time-minutes-field');

            my $max_time = ($max_time_days * 60 * 24) + ($max_time_hours * 60) + $max_time_minutes;

            $self->store_data({ max_time => $max_time });
        }

        my $max_num_time = $self->retrieve_data('max_time');

        if ( $max_num_time eq '0' ) {
            $max_num_time = '';
        }

        $template->param(
            op => $op,
            max_time => $max_num_time,

        );
    }
    elsif ( $op eq 'max-future-date' ) {

        my $submitted = $cgi->param('max-submitted') || q{};

        if ( $submitted eq '1' ) {

            my $max_days = $cgi->param('max-days-field');

            $self->store_data({ max_future_days => $max_days });
        }

        my $max_num_days = $self->retrieve_data('max_future_days');

        if ( $max_num_days eq '0' ) {
            $max_num_days = '';
        }

        $template->param(
            op => $op,
            max_num_days => $max_num_days,

        );
    }
    elsif ( $op eq 'display-rooms' ) {

        my $roomnumbers = getAllRoomNumbers();

        $template->param(
            op          => $op,
            roomnumbers => $roomnumbers,
        );
    }
    elsif ( $op eq 'display-rooms-detail' ) {

        my $roomIdToDisplay = $cgi->param('selected-displayed-room');

        my $roomDetails = getRoomDetailsById($roomIdToDisplay);

        my $roomEquipment = getRoomEquipmentById($roomIdToDisplay);

        $template->param(
            op => $op,
            selected_room_details => $roomDetails,
            selected_room_equipment => $roomEquipment,
        );
    }
    elsif ( $op eq 'add-rooms' ) {

        my $addedRoom = $cgi->param('added-room') || q{};

        if ($addedRoom eq '1') {
            my $roomnumber = $cgi->param('add-room-roomnumber');
            my $maxcapacity = $cgi->param('add-room-maxcapacity');
            my $description = $cgi->param('add-room-description');
            my @selectedEquipment = $cgi->param('selected-equipment');

            ## pass @selectedEquipment by reference
            addRoom($roomnumber, $maxcapacity, $description, \@selectedEquipment);
        }

        my $availableEquipment = getAllRoomEquipmentNamesAndIds();
        my $roomNumbers = getCurrentRoomNumbers();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
            all_room_numbers => $roomNumbers,
        );
    }
    elsif ( $op eq 'edit-rooms' ) {

        my $editing = $cgi->param('editing') || q{};
        my $roomDetailsUpdated = $cgi->param('room-details-updated') || q{};
        my $roomEquipmentUpdated = $cgi->param('room-equipment-updated') || q{};

        if ($editing eq '1') {
            my $selectedRoomId = $cgi->param('current-rooms-edit');

            $template->param(
                selected_room_id => $selectedRoomId,
            );
        }

        if ( $roomDetailsUpdated eq '1' ) {
            my $roomIdToUpdate = $cgi->param('room-details-updated-roomid');
            my $updatedRoomNumber = $cgi->param('edit-rooms-room-roomnumber');
            my $updatedMaxCapacity = $cgi->param('edit-rooms-room-maxcapacity');
            my $updatedDescription = $cgi->param('edit-rooms-room-description');

            updateRoomDetails($roomIdToUpdate, $updatedRoomNumber, $updatedDescription, $updatedMaxCapacity);
        }

        if ( $roomEquipmentUpdated eq '1' ) {
            my $equipmentRoomId = $cgi->param('room-equipment-updated-roomid');
            my @equipmentIdArray = $cgi->param('edit-rooms-current-equipment');

            updateRoomEquipment($equipmentRoomId, \@equipmentIdArray);
        }

        my $roomNumbers = getAllRoomNumbers();

        $template->param(
            op => $op,
            current_rooms => $roomNumbers,
        );
    }
    elsif ( $op eq 'edit-rooms-selection' ) {

        my $choice = $cgi->param('edit-rooms-choice') || q{};

        my $selectedRoomId = $cgi->param('current-rooms-edit') || q{};

        my $editAction = '';

        if ( $choice eq 'room' ) {

            $editAction = 'edit-rooms-room';
        }

        if ( $choice eq 'equipment' ) {

            $editAction = 'edit-rooms-equipment';
        }

        $template->param(
            op => $op,
            edit_action => $editAction,
            selected_room_id => $selectedRoomId,
        );
    }
    elsif ( $op eq 'edit-rooms-room' ) {

        my $selectedRoomId = $cgi->param('selected-room-id') || q{};

        my $roomDetails = loadRoomDetailsToEditByRoomId($selectedRoomId);

        $template->param(
            op => $op,
            room_details => $roomDetails,
        );
    }
    elsif ( $op eq 'edit-rooms-equipment' ) {

        my $selectedRoomId = $cgi->param('selected-room-id') || q{};

        my $roomDetails = loadRoomDetailsToEditByRoomId($selectedRoomId);

        my $allAvailableEquipment = loadAllEquipment();

        $template->param(
            op => $op,
            room_details => $roomDetails,
            all_available_equipment => $allAvailableEquipment,
        );
    }
    elsif ( $op eq 'delete-rooms' ) {

        my $delete = $cgi->param('delete') || q{};

        if ( $delete eq '1' ) {
            my $roomIdToDelete = $cgi->param('delete-room-radio-button');

            deleteRoom($roomIdToDelete);
        }

        my $availableRooms = getAllRoomNumbersAndIdsAvailableToDelete();

        my $areThereRoomsToDelete = areAnyRoomsAvailableToDelete($availableRooms);

        if ($areThereRoomsToDelete == 1) {
            $template->param(
                rooms_available_to_delete => 1,
            );
        }
        else {
            $template->param(
                rooms_available_to_delete => 0,
            );
        }

        $template->param(
            op => $op,
            available_rooms => $availableRooms,
            rooms_available_to_delete => 1,
        );
    }
    elsif ( $op eq 'add-equipment' ) {

        my $insert = $cgi->param('insert') || q{};

        if ( $insert eq '1') {
            my $addedEquipment = $cgi->param('add-equipment-text-field');

            ## Convert to lowercase to enforce uniformity
            $addedEquipment = lc($addedEquipment);

            ## Enclose in single quotes for DB string compatibility
            $addedEquipment = "'" . $addedEquipment . "'";

            addEquipment($addedEquipment);
        }

        my $availableEquipment = getAllRoomEquipmentNames();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
        );
    }
    elsif ( $op eq 'delete-equipment' ) {

        my $delete = $cgi->param('delete') || q{};

        if ( $delete eq '1' ) {
            my $equipmentIdToDelete = $cgi->param('delete-equipment-radio-button');

            deleteEquipment($equipmentIdToDelete);
        }

        my $availableEquipment = getAllRoomEquipmentNamesAndIdsAvailableToDelete();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
        );
    }
    elsif ( $op eq 'edit-equipment-selection' ) {

        my $availableEquipment = getAllRoomEquipmentNamesAndIds();

        $template->param(
            op => $op,
            available_equipment => $availableEquipment,
        );
    }
    elsif ( $op eq 'edit-equipment' ) {
		
		my $edit = $cgi->param('edit') || q{};

        if ( $edit eq '1') {
			my $editedEquipmentId = $cgi->param('edit-equipment-id'); 
            my $editedEquipmentName = $cgi->param('edit-equipment-text-field');

            ## Convert to lowercase to enforce uniformity
            $editedEquipmentName = lc($editedEquipmentName);

            ## Enclose in single quotes for DB string compatibility
            $editedEquipmentName = "'" . $editedEquipmentName . "'";

            updateEquipment($editedEquipmentId, $editedEquipmentName);
            
            my $availableEquipment = getAllRoomEquipmentNamesAndIds();

			$template->param(
				op => 'edit-equipment-selection',
				available_equipment => $availableEquipment,
			);
        }
        else {
			my $equipmentIdToEdit = $cgi->param('edit-equipment-radio-button');
			my $equipmentToEdit = getEquipmentById($equipmentIdToEdit);
			
			$template->param(
				op => $op,
				equipment_to_edit => $equipmentToEdit,
			);
		}
    }
    

    print $cgi->header(-type => 'text/html',-charset => 'utf-8');
    print $template->output();
}

sub getCurrentTimestamp {

    my $timestamp = strftime('%m/%d/%Y %I:%M:%S %p', localtime);

    return $timestamp;
}

sub getAllOpeningHours {
	
	my $convertWeekdays = 0;
	$convertWeekdays = shift;
	
    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT openid,day, DATE_FORMAT(start, '%H:%i') as start, DATE_FORMAT(end, '%H:%i') as end
        FROM $openinghours_table
        ORDER BY day ASC, start ASC;";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allOpeningHours;

    while ( my $row = $sth->fetchrow_hashref() ) {
		if ($convertWeekdays == 1) {
			if ($row->{day} == 1){
				$row->{day} = "Monday";
			} elsif ($row->{day} == 2){
				$row->{day} = "Tuesday";
			} elsif ($row->{day} == 3){
				$row->{day} = "Wednesday";
			} elsif ($row->{day} == 4){
				$row->{day} = "Thursday";
			} elsif ($row->{day} == 5){
				$row->{day} = "Friday";
			} elsif ($row->{day} == 6){
				$row->{day} = "Saturday";
			} elsif ($row->{day} == 7){
				$row->{day} = "Sunday";
			} 
		}
        push ( @allOpeningHours, $row );
    }

    return \@allOpeningHours;
}

sub getAllBookings {

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT bk.bookingid, r.roomnumber, b.borrowernumber, b.firstname, b.surname, DATE_FORMAT(bk.start, \"%d.%m.%Y %H:%i\") AS start, DATE_FORMAT(bk.end, \"%d.%m.%Y %H:%i\") AS end
        FROM borrowers b, $bookings_table bk, $rooms_table r
        WHERE b.borrowernumber = bk.borrowernumber
        AND bk.roomid = r.roomid
        ORDER BY bk.roomid ASC, bk.start DESC;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allBookings;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allBookings, $row );
    }

    return \@allBookings;
}

sub getRestrictedPatronCategories {

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT categorycode, description
        FROM categories, plugin_data
        WHERE plugin_class = 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations'
        AND plugin_key LIKE 'rcat_%'
        AND plugin_value = categorycode;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @categories;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @categories, $row );
    }

    return \@categories;
}

sub clearPatronCategoryRestriction {

    my ($restricted_category) = @_;

    my $delete_query;

    unless (defined $restricted_category) {
        my $dbh = C4::Context->dbh;

        $delete_query = "
            DELETE FROM plugin_data
            WHERE plugin_class = 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations'
            AND plugin_key LIKE 'rcat_%';";

        $dbh->do($delete_query);
    }
    else {
        my @restricted = @$restricted_category;

        my $counter = scalar(@restricted);

        my $dbh = C4::Context->dbh;

        $delete_query = "
            DELETE FROM plugin_data
            WHERE plugin_class = 'Koha::Plugin::Com::MarywoodUniversity::RoomReservations'
            AND plugin_key LIKE 'rcat_%'";

        if ($counter == 0) {
            $delete_query .= ";";
        }
        else {
            $delete_query .= " AND plugin_value NOT IN (";

            for my $code (@restricted) {

                if ($counter > 0 && $counter != 1) {
                    $delete_query .= "'$code', ";
                }
                else {
                    $delete_query .= "'$code'";
                }

                $counter--;
            }

            $delete_query .= ");";
        }

        $dbh->do($delete_query);
    }
}

sub getPatronCategories {

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT categorycode, description
        FROM categories
        ORDER BY categorycode ASC;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @categories;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @categories, $row );
    }

    return \@categories;
}

sub getAllBlackedoutBookings {

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        SELECT bk.bookingid, r.roomnumber, DATE_FORMAT(bk.start, \"%d.%m.%Y %H:%i\") AS start, DATE_FORMAT(bk.end, \"%d.%m.%Y %H:%i\") AS end
        FROM $bookings_table bk, $rooms_table r
        WHERE bk.roomid = r.roomid
        AND bk.blackedout = 1
        AND bk.start BETWEEN CAST(CONCAT(CURDATE(), \" 00:00:00\") AS DATETIME) AND CAST(CONCAT(DATE_ADD(CURDATE(), INTERVAL 30 DAY), \" 23:59:59\") AS DATETIME)
        ORDER BY bk.start ASC;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allBlackedoutBookings;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allBlackedoutBookings, $row );
    }

    return \@allBlackedoutBookings;
}

sub addBlackoutBooking {

    my ( $borrowernumber, $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("
        INSERT INTO $bookings_table (borrowernumber, roomid, start, end, blackedout)
        VALUES ($borrowernumber, $roomid, " . "'" . $start . "'" . "," . "'" . $end . "'" . ', 1);');
}

sub deleteOpeningHoursById {

    my ( $openId ) = @_;

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        DELETE FROM booking_opening_hours WHERE openid = $openId;
    ";

    $sth = $dbh->prepare($query);

    my $count = $sth->execute();

    if ($count == 0) { # no row(s) affected
        return 0;
    }
    else { # sucessfully deleted row(s)
        return 1;
    }
}

sub deleteBookingById {

    my ( $bookingId ) = @_;

    my $dbh = C4::Context->dbh;

    my $sth = '';

    my $query = "
        DELETE FROM bookings WHERE bookingid = $bookingId;
    ";

    $sth = $dbh->prepare($query);

    my $count = $sth->execute();

    if ($count == 0) { # no row(s) affected
        return 0;
    }
    else { # sucessfully deleted row(s)
        return 1;
    }
}

sub areAnyRoomsAvailableToDelete {

    my ( $rooms ) = @_;

    if ( @$rooms > 0 ) {
        # return true
        return 1;
    }
    else {
        # return false
        return 0;
    }
}

sub updateRoomDetails {

    my ( $roomid, $roomnumber, $description, $maxcapacity) = @_;

    $roomnumber = "'" . $roomnumber . "'";
    $description = "'" . $description . "'";

    ## load access to database
    my $dbh = C4::Context->dbh;

    my $query = "
        UPDATE $rooms_table
        SET roomnumber = $roomnumber, maxcapacity = $maxcapacity, description = $description
        WHERE roomid = $roomid;";

    $dbh->do($query);
}

sub updateRoomEquipment {

    my ( $roomid, $equipment ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $roomequipment_table WHERE roomid = $roomid;");

    foreach my $piece (@$equipment) {

        $dbh->do("INSERT INTO $roomequipment_table (roomid, equipmentid) VALUES ($roomid, $piece);");
    }
}

sub loadRoomDetailsToEditByRoomId {

    my ( $roomid ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $rooms_table
        WHERE roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @roomDetails;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @roomDetails, $row );
    }

    return \@roomDetails;
}

sub loadAllEquipment {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $equipment_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allAvailableEquipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allAvailableEquipmentNames, $row );
    }

    return \@allAvailableEquipmentNames;
}

## DO NOT USE - causes strange TT software errors
sub loadRoomEquipmentNamesToEditByRoomId {

    my ( $roomid ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT e.equipmentname
        FROM $equipment_table AS e, $roomequipment_table AS re
        WHERE re.equipmentid = e.equipmentid
        AND re.roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @equipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @equipmentNames, $row );
    }

    return \@equipmentNames;
}

sub addRoom {

    my ($roomnumber, $maxcapacity, $description, $equipment) = @_;

    ## make $roomnumber SQL-friendly by surrounding with single quotes
    $roomnumber = "'" . $roomnumber . "'";
    $description = "'" . $description . "'";

    my $dbh = C4::Context->dbh;

    ## first insert roomnumber and maxcapacity into $rooms_table
    $dbh->do("INSERT INTO $rooms_table (roomnumber, maxcapacity, description) VALUES ($roomnumber, $maxcapacity, $description);");

    foreach my $piece (@$equipment) {

        $dbh->do("INSERT INTO $roomequipment_table (roomid, equipmentid) VALUES ((SELECT roomid FROM $rooms_table WHERE roomnumber = $roomnumber), $piece);");
    }
}

sub deleteRoom {

    my ($roomId) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $roomequipment_table WHERE roomid = $roomId");

    $dbh->do("DELETE FROM $rooms_table WHERE roomid = $roomId");
}

sub addEquipment {

    my ( $equipmentname ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("INSERT INTO $equipment_table (equipmentname) VALUES ($equipmentname);");
}

sub updateEquipment {

    my ( $equipmentid, $equipmentname ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("UPDATE $equipment_table SET equipmentname = $equipmentname WHERE equipmentid = $equipmentid;");
}

sub deleteEquipment {

    my ( $equipmentId ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("DELETE FROM $equipment_table WHERE equipmentid = $equipmentId");
}

sub countRooms {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT COUNT(roomid) AS count
        FROM $rooms_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my $row = $sth->fetchrow_hashref();

    my $count = $row->{'count'};

    return $count;
}

sub getAllRooms {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $rooms_table
        ORDER BY roomnumber;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRooms;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRooms, $row );
    }

    return \@allRooms;
}

sub getAllRoomIds {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid
        FROM $rooms_table
        ORDER BY roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomIds, $row );
    }

    return \@allRoomIds;
}

sub getCurrentRoomNumbers {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid, roomnumber
        FROM $rooms_table
        ORDER BY roomnumber;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomNumbers;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomNumbers, $row );
    }

    return \@allRoomNumbers;
}

sub getAllRoomEquipmentNames {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentname
        FROM $equipment_table
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNames;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNames, $row );
    }

    return \@allEquipmentNames;
}

sub getAllRoomEquipmentNamesAndIds {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentid, equipmentname
        FROM $equipment_table
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNamesAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNamesAndIds, $row );
    }

    return \@allEquipmentNamesAndIds;
}

sub getAllRoomEquipmentNamesAndIdsAvailableToDelete {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentid, equipmentname
        FROM $equipment_table
        WHERE equipmentid NOT IN
            (SELECT equipmentid FROM $roomequipment_table)
        ORDER BY equipmentname;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allEquipmentNamesAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allEquipmentNamesAndIds, $row );
    }

    return \@allEquipmentNamesAndIds;
}

sub getAllRoomNumbersAndIdsAvailableToDelete {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid, roomnumber
        FROM $rooms_table
        WHERE roomid NOT IN
            (SELECT roomid FROM $bookings_table)
        ORDER BY roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRoomNumbersAndIds;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRoomNumbersAndIds, $row );
    }

    return \@allRoomNumbersAndIds;
}

sub getRoomDetailsById {

    my ( $selectedRoomId ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    ## Note: GROUP BY is used to prevent duplication of rows in next step
    my $query = "
        SELECT r.roomnumber, r.maxcapacity, r.description, e.equipmentname
        FROM $rooms_table AS r, $equipment_table AS e, $roomequipment_table AS re
        WHERE r.roomid = re.roomid
        AND   e.equipmentid = re.equipmentid
        AND r.roomid = $selectedRoomId
        GROUP BY r.roomnumber;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @selectedRoomDetails;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @selectedRoomDetails, $row );
    }

    return \@selectedRoomDetails;
}

sub getEquipmentById {

    my ( $selectedEquipmentId ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT equipmentid,equipmentname
        FROM $equipment_table
        WHERE equipmentid = $selectedEquipmentId;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @selectedEquipment;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @selectedEquipment, $row );
    }

    return \@selectedEquipment;
}

sub getRoomEquipmentById {

    my ( $selectedRoomId ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT e.equipmentname
        FROM $equipment_table AS e, $roomequipment_table AS re
        WHERE e.equipmentid = re.equipmentid
        AND re.roomid = $selectedRoomId;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @selectedRoomEquipment;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @selectedRoomEquipment, $row );
    }

    return \@selectedRoomEquipment;
}

## Used in display-rooms
## Returns an array
## Key: roomnumber
## Value: maxcapacity
sub getAllRoomNumbers {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = '';

    ## room selection query
    $query = "SELECT * FROM $rooms_table;";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allRooms;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allRooms, $row );
    }

    return \@allRooms;
}

sub loadAllMaxCapacities {

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT DISTINCT maxcapacity
        FROM $rooms_table;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allMaxCapacities;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allMaxCapacities, $row );
    }

    return \@allMaxCapacities;
}

sub getAvailableRooms {

    my ( $start, $end, $capacity, $equipment ) = @_;

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT *
        FROM $rooms_table
        WHERE maxcapacity = $capacity
        AND roomid NOT IN
            (SELECT roomid
            FROM $bookings_table
            WHERE
            \'$end\' > start AND \'$start\' < end)";

        # if dereferenced array ref has zero elements (length evaluated in scalar context)
        if ( @$equipment > 0 ) {

            # counts number of elements
            my $totalElements = scalar @{ $equipment };

            $query .= " AND roomid IN (SELECT roomid
                                        FROM $roomequipment_table
                                        WHERE";

            foreach my $piece (@$equipment) {

                if ( --$totalElements == 0 ) {

                    $query .= " equipmentid = $piece)";
                }
                else {
                    $query .= " equipmentid = $piece AND";
                }

                $totalElements--;
            }
        }

        $query .= ' GROUP BY roomnumber;';

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @allAvailableRooms;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allAvailableRooms, $row );
    }

    return \@allAvailableRooms;
}

sub areAnyRoomsAvailable {

    my ( $rooms ) = @_;

    if ( @$rooms > 0 ) {
        # return true
        return 1;
    }
    else {
        # return false
        return 0;
    }
}

sub getRoomNumberById {

    my ( $roomid ) = @_;

    # load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomnumber
        FROM $rooms_table
        WHERE roomid = $roomid;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my @roomNumberFromId;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @roomNumberFromId, $row );
    }

    return \@roomNumberFromId;
}

sub preBookingAvailabilityCheck {
    my ( $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT COUNT(*)
        FROM $bookings_table
        WHERE roomid = $roomid
        AND \'$end\' > start
        AND \'$start\' < end;
    ";

    $sth = $dbh->prepare($query);
    $sth->execute();

    my ($count) = $sth->fetchrow_array();

    if ($count > 0) { # a conflicting booking was found
        return 0;
    }
    else { # no conflict found
        return 1;
    }
}

sub checkOpeningHours {
	my ( $datetime ) = @_;
	my $result = 0;
	
	## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';
    
    my $weekday = $datetime->day_of_week;

    my $query = "
        SELECT start, end
            FROM $openinghours_table
            WHERE day = $weekday;";

    $sth = $dbh->prepare($query);
    $sth->execute();
    
    my @allOpeningsOnWeekday;

    while ( my $row = $sth->fetchrow_hashref() ) {
        push ( @allOpeningsOnWeekday, $row );
    }
    
    foreach my $openingHour (@allOpeningsOnWeekday) {
		
		my @times = split /:/, $openingHour->{start};
		my $dt_start = DateTime->new(
			year      => $datetime->year,
			month     => $datetime->month,
			day       => $datetime->day,
			hour      => $times[0],
			minute    => $times[1],
		);
		
		@times = split /:/, $openingHour->{end};
		my $dt_end = DateTime->new(
			year      => $datetime->year,
			month     => $datetime->month,
			day       => $datetime->day,
			hour      => $times[0],
			minute    => $times[1],
		);
		
		if (DateTime->compare($datetime, $dt_start) >= 0 && DateTime->compare($datetime, $dt_end) <= 0) {
			$result = 1;
			last;
		}
	}
	
	return $result;
}

sub checkRoomAvailability {

    my ( $room_id, $start, $end ) = @_;
    
    # check if start and end time are in opening hours
    if (checkOpeningHours($start) == 0 || checkOpeningHours($end) == 0) {
		return 0;
	}    

    ## load access to database
    my $dbh = C4::Context->dbh;

    ## database statement handler
    my $sth = '';

    my $query = "
        SELECT roomid
            FROM $bookings_table
            WHERE
            \'$end\' > start AND \'$start\' < end;
            ";
            
    
    $sth = $dbh->prepare($query);
    my $count = $sth->execute();

    if ($count != 0) {
		return 0;
	} 
	
	return 1;
}

sub addOpeningHours {

    my ( $days, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;
    
    my $day_cnt = 0;
    foreach my $day (@$days) {
		if ($day) {
			$dbh->do("
				INSERT INTO $openinghours_table (day, start, end)
				VALUES ($day, '$start', '$end');");
		}
		$day_cnt++;
	}
}

sub addBooking {

    my ( $borrowernumber, $roomid, $start, $end ) = @_;

    my $dbh = C4::Context->dbh;

    $dbh->do("
        INSERT INTO $bookings_table (borrowernumber, roomid, start, end)
        VALUES ($borrowernumber, $roomid, " . "'" . $start . "'" . "," . "'" . $end . "'" . ');');
}

sub getTranslation {
  my ( $string ) = @_;
  return Encode::decode('UTF-8', gettext($string));
}

1;
