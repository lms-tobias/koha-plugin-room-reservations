setTimeout(() => {
  document.getElementById('room-booking').scrollIntoView();
}, 500);

const availabilitySearchForm = document.querySelector('form[name="availabilitySearchForm"]');
const availabilitySearchSubmitButton = document.querySelector('input[name="submit-check-room-availability"]');

availabilitySearchForm.addEventListener('submit', (e) => {
  const searchForm = {
    sd: {
      field: document.getElementById('availability-search-start-date'),
      value: document.getElementById('availability-search-start-date').value,
    },
    st: {
      field: document.getElementById('availability-search-start-time'),
      value: document.getElementById('availability-search-start-time').value,
    },
    ed: {
      field: document.getElementById('availability-search-end-date'),
      value: document.getElementById('availability-search-end-date').value,
    },
    et: {
      field: document.getElementById('availability-search-end-time'),
      value: document.getElementById('availability-search-end-time').value,
    },
    ro: {
      field: document.getElementById('availability-search-room'),
      value: document.getElementById('availability-search-room').value,
    },
  };

  const searchFormArray = Array.from(Object.entries(searchForm));

  searchFormArray.forEach((entry) => { const [, values] = entry; if (values.field.classList.contains('border-danger')) { values.field.classList.toggle('border-danger'); } });

  const MINUTES_TO_MILLISECONDS = 60000;
  const MILLISECONDS_TO_HOURS = 3600000;

  const maximumTimeframe = parseInt(document.getElementById('max_time').value);
  const maximumTimeframeInMilliseconds = maximumTimeframe !== 0 ? maximumTimeframe * MINUTES_TO_MILLISECONDS : 0;
  const maximumTimeframeInHours = maximumTimeframeInMilliseconds !== 0 ? (maximumTimeframeInMilliseconds / MILLISECONDS_TO_HOURS) % 24 : 0;

  const startTimestamp = `${searchForm.sd.value} ${searchForm.st.value}`;
  const endTimestamp = `${searchForm.ed.value} ${searchForm.et.value}`;

  const startTimestampInMilliseconds = Date.parse(startTimestamp);
  const endTimestampInMilliseconds = Date.parse(endTimestamp);

  const timeDifferenceInMilliseconds = endTimestampInMilliseconds - startTimestampInMilliseconds;

  if (
    timeDifferenceInMilliseconds > maximumTimeframeInMilliseconds
      && maximumTimeframeInMilliseconds > 0
  ) {
    let timeString = '';

    if (maximumTimeframeInHours > 0) {
      timeString += `${maximumTimeframeInHours} [% 'hours' | gettext %]`;
    }

    e.preventDefault();
    alert(
      `[% 'Selected time range exceeds maximum time allowed of' | gettext %] ${timeString}!`,
    );
    return false;
  }

  searchFormArray.forEach((entry) => {
    const [, values] = entry;
    if (values.value === '') {
      values.field.classList.toggle('border-danger');
    }
  });

  if (searchFormArray.some((entry) => { const [, values] = entry; return values.value === ''; })) { e.preventDefault(); return false; }

  return undefined;
});

availabilitySearchSubmitButton.disabled = false;
